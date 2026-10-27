unit XVReadWMF;

{$mode delphi}{$H+}
{$R-}{$Q-}

// XelVectors - Windows Metafile (WMF) reader: the records are played on the
// GDI emulator (XVGdiPlay). Placeable (Aldus) headers give the picture
// rectangle and its size; without one the window extent is the picture.

interface

uses
  SysUtils, Classes, Math, XVModel, XVImageCodec, XVGdiPlay;

function XVIsWMF(const Data: TBytes): Boolean;
procedure XVReadWMFDoc(Doc: TXVDocument; const Data: TBytes);

implementation

function U16(const D: TBytes; p: Integer): Integer; inline;
begin
  if (p < 0) or (p + 2 > Length(D)) then Exit(0);
  Result := D[p] or (D[p + 1] shl 8);
end;

function S16(const D: TBytes; p: Integer): Integer; inline;
begin
  Result := SmallInt(Word(U16(D, p)));
end;

function U32(const D: TBytes; p: Integer): Cardinal; inline;
begin
  if (p < 0) or (p + 4 > Length(D)) then Exit(0);
  Result := Cardinal(D[p]) or (Cardinal(D[p + 1]) shl 8) or (Cardinal(D[p + 2]) shl 16) or (Cardinal(D[p + 3]) shl 24);
end;

function ColorAt(const D: TBytes; p: Integer): TXVColor;
begin
  Result := XVBGRToColor(U32(D, p) and $FFFFFF);
end;

function XVIsWMF(const Data: TBytes): Boolean;
begin
  Result := False;
  if Length(Data) < 18 then Exit;
  if U32(Data, 0) = $9AC6CDD7 then Exit(True);
  // standard header: type 1 or 2, header size 9 words, version 0x0100 / 0x0300
  Result := (U16(Data, 0) in [1, 2]) and (U16(Data, 2) = 9) and ((U16(Data, 4) = $0300) or (U16(Data, 4) = $0100));
end;

type
  TWmfReader = class
    D: TBytes;
    P: TXVGdiPlayer;
    Doc: TXVDocument;
    procedure ReadPen(q: Integer);
    procedure ReadBrush(q: Integer);
    procedure ReadFont(q, Len: Integer);
    procedure ReadDibBrush(q, Len: Integer);
    procedure ReadRegion(q, Len: Integer);
    function Pts(q, N: Integer): TXVPoints;
    procedure Text(q, Len: Integer; Ext: Boolean);
    procedure Record_(Func, q, Len: Integer);
    procedure Run;
  end;

procedure AddObj(P: TXVGdiPlayer; const O: TGdiObj);
begin
  P.SetObject(P.FreeSlot, O);
end;

procedure TWmfReader.ReadPen(q: Integer);
var O: TGdiObj;
begin
  O := Default(TGdiObj);
  O.Kind := goPen;
  O.Pen.Style := U16(D, q);
  O.Pen.Width := S16(D, q + 2);
  O.Pen.Color := ColorAt(D, q + 6);
  O.Pen.Cosmetic := O.Pen.Width <= 1;
  O.Pen.BrushImage := -1;
  // WMF pens are geometric when wider than one unit: round caps and joins
  if not O.Pen.Cosmetic then O.Pen.Style := O.Pen.Style or $00010000;
  AddObj(P, O);
end;

procedure TWmfReader.ReadBrush(q: Integer);
var O: TGdiObj;
begin
  O := Default(TGdiObj);
  O.Kind := goBrush;
  O.Brush.Style := U16(D, q);
  O.Brush.Color := ColorAt(D, q + 2);
  O.Brush.Hatch := U16(D, q + 6);
  O.Brush.Image := -1;
  if O.Brush.Style in [3, 5, 6] then O.Brush.Style := 0;    // pattern without bitmap data
  AddObj(P, O);
end;

procedure TWmfReader.ReadDibBrush(q, Len: Integer);
var
  O: TGdiObj;
  img: TXVImage;
  style: Integer;
begin
  O := Default(TGdiObj);
  O.Kind := goBrush;
  style := U16(D, q);
  O.Brush.Image := -1;
  O.Brush.Style := 0;
  O.Brush.Color := XVRGB($80, $80, $80);
  if (style = 5) or (style = 3) then
  begin
    if XVDecodeDIB(D, q + 4, Len - 4, -1, Len - 4, img) then
    begin
      O.Brush.Image := Doc.AddImageData(img);
      O.Brush.Style := 5;
      O.Brush.Color := XVImageAverage(img);
    end;
  end;
  AddObj(P, O);
end;

procedure TWmfReader.ReadFont(q, Len: Integer);
var
  O: TGdiObj;
  i, n: Integer;
  face: TBytes;
begin
  O := Default(TGdiObj);
  O.Kind := goFont;
  O.Font.Height := S16(D, q);
  O.Font.Width := S16(D, q + 2);
  O.Font.Escapement := S16(D, q + 4);
  O.Font.Orientation := S16(D, q + 6);
  O.Font.Weight := S16(D, q + 8);
  if q + 17 < Length(D) then
  begin
    O.Font.Italic := D[q + 10] <> 0;
    O.Font.Underline := D[q + 11] <> 0;
    O.Font.Strike := D[q + 12] <> 0;
    O.Font.CharSet := D[q + 13];
  end;
  n := 0;
  SetLength(face, 32);
  for i := 0 to 31 do
  begin
    if (q + 18 + i >= Length(D)) or (18 + i >= Len) or (D[q + 18 + i] = 0) then Break;
    face[n] := D[q + 18 + i];
    Inc(n);
  end;
  O.Font.Face := Trim(XVCodePageToUtf8(face, 0, n, 1252));
  AddObj(P, O);
end;

procedure TWmfReader.ReadRegion(q, Len: Integer);
var
  O: TGdiObj;
  nScans, i, j, cnt, top, bottom, k: Integer;
  x1, x2: Integer;
  pts: array[0..3] of TXVPoint;
begin
  // REGION: nextInChain, objectType, objectCount, regionSize, scanCount, maxScan, bbox, scans
  O := Default(TGdiObj);
  O.Kind := goRegion;
  O.Region.Clear;
  nScans := S16(D, q + 10);
  k := q + 22;
  for i := 0 to nScans - 1 do
  begin
    if k + 6 > q + Len then Break;
    cnt := U16(D, k);
    top := S16(D, k + 2); bottom := S16(D, k + 4);
    Inc(k, 6);
    for j := 0 to cnt div 2 - 1 do
    begin
      x1 := S16(D, k); x2 := S16(D, k + 2);
      Inc(k, 4);
      pts[0] := P.Map(x1, top); pts[1] := P.Map(x2, top); pts[2] := P.Map(x2, bottom); pts[3] := P.Map(x1, bottom);
      O.Region.AddPolygon(pts, True);
    end;
    Inc(k, 2);
  end;
  AddObj(P, O);
end;

function TWmfReader.Pts(q, N: Integer): TXVPoints;
var i: Integer;
begin
  SetLength(Result, Max(0, N));
  for i := 0 to N - 1 do
  begin
    Result[i].X := S16(D, q + 4 * i);
    Result[i].Y := S16(D, q + 4 * i + 2);
  end;
end;

procedure TWmfReader.Text(q, Len: Integer; Ext: Boolean);
var
  x, y, n, opts, sp, i: Integer;
  r: TXVRect;
  haveRect: Boolean;
  s: string;
  dx: array of Double;
  cp: Integer;
  chars: TStringArray;
begin
  haveRect := False;
  r := XVRect(0, 0, 0, 0);
  opts := 0;
  if Ext then
  begin
    y := S16(D, q); x := S16(D, q + 2);
    n := U16(D, q + 4);
    opts := U16(D, q + 6);
    sp := q + 8;
    if (opts and 6) <> 0 then
    begin
      r := XVRect(S16(D, sp), S16(D, sp + 2), S16(D, sp + 4), S16(D, sp + 6));
      haveRect := True;
      Inc(sp, 8);
    end;
  end
  else
  begin
    n := U16(D, q);
    sp := q + 2;
    y := S16(D, sp + ((n + 1) and not 1));
    x := S16(D, sp + ((n + 1) and not 1) + 2);
  end;
  if n < 0 then Exit;
  n := Min(n, Max(0, Length(D) - sp));
  cp := XVCharsetCodePage(P.S.Font.CharSet);
  if P.S.Font.CharSet = 2 then cp := 0;
  s := XVCodePageToUtf8(D, sp, n, cp);
  dx := nil;
  if Ext and (sp + ((n + 1) and not 1) + 2 * n <= q + Len) then
  begin
    // one advance per byte; multi-byte characters keep the sum
    chars := XVUtf8Chars(s);
    if Length(chars) = n then
    begin
      SetLength(dx, n);
      for i := 0 to n - 1 do dx[i] := S16(D, sp + ((n + 1) and not 1) + 2 * i);
    end;
  end;
  P.TextOut(x, y, s, dx, opts, r, haveRect);
end;

procedure TWmfReader.Record_(Func, q, Len: Integer);
var
  n, i, k, total, rop: Integer;
  counts: array of Integer;
  pp: TXVPoints;
  img: TXVImage;
  dibOfs: Integer;
  b: TGdiBrush;
  O: TGdiObj;
begin
  case Func of
    $0103: P.S.BkMode := U16(D, q);
    $0104: P.SetMapMode(U16(D, q));
    $0105: P.S.Rop2 := U16(D, q);
    $0107: P.S.FillMode := U16(D, q);
    $0109: P.S.CharExtra := S16(D, q);
    $012E: P.S.TextAlign := U16(D, q);
    $0201: P.S.BkColor := ColorAt(D, q);
    $0209: P.S.TextColor := ColorAt(D, q);
    $020B: P.SetWindowOrg(S16(D, q + 2), S16(D, q));
    $020C: P.SetWindowExt(S16(D, q + 2), S16(D, q));
    $020D: P.SetViewportOrg(S16(D, q + 2), S16(D, q));
    $020E: P.SetViewportExt(S16(D, q + 2), S16(D, q));
    $020F: P.SetWindowOrg(P.S.WinOrgX + S16(D, q + 2), P.S.WinOrgY + S16(D, q));
    $0211: P.SetViewportOrg(P.S.VpOrgX + S16(D, q + 2), P.S.VpOrgY + S16(D, q));
    $0410: P.ScaleWindowExt(S16(D, q + 6), S16(D, q + 4), S16(D, q + 2), S16(D, q));
    $0412: P.ScaleViewportExt(S16(D, q + 6), S16(D, q + 4), S16(D, q + 2), S16(D, q));
    $001E: P.SaveDC;
    $0127: P.RestoreDC(S16(D, q));
    $012D: P.SelectObject(U16(D, q));
    $01F0: P.DeleteObject(U16(D, q));
    $02FA: ReadPen(q);
    $02FC: ReadBrush(q);
    $02FB: ReadFont(q, Len);
    $0142: ReadDibBrush(q, Len);
    $01F9: begin
             // CREATEPATTERNBRUSH with a device dependent bitmap: grey
             O := Default(TGdiObj); O.Kind := goBrush; O.Brush.Color := XVRGB($80, $80, $80); O.Brush.Image := -1;
             AddObj(P, O);
           end;
    $06FF: ReadRegion(q, Len);
    $00F7: begin O := Default(TGdiObj); O.Kind := goPalette; AddObj(P, O); end;
    $06FE: begin O := Default(TGdiObj); O.Kind := goOther; AddObj(P, O); end;
    $0213: P.LineTo(S16(D, q + 2), S16(D, q));
    $0214: P.MoveTo(S16(D, q + 2), S16(D, q));
    $0324: begin n := S16(D, q); P.Polygon(Pts(q + 2, n)); end;
    $0325: begin n := S16(D, q); P.Polyline(Pts(q + 2, n), False); end;
    $0538: begin
             n := U16(D, q);
             SetLength(counts, n);
             total := 0;
             for i := 0 to n - 1 do
             begin
               counts[i] := U16(D, q + 2 + 2 * i);
               Inc(total, counts[i]);
             end;
             P.PolyPolygon(Pts(q + 2 + 2 * n, total), counts);
           end;
    $041B: P.Rectangle(S16(D, q + 6), S16(D, q + 4), S16(D, q + 2), S16(D, q));
    $0418: P.Ellipse(S16(D, q + 6), S16(D, q + 4), S16(D, q + 2), S16(D, q));
    $061C: P.RoundRect(S16(D, q + 10), S16(D, q + 8), S16(D, q + 6), S16(D, q + 4), S16(D, q + 2), S16(D, q));
    $0817, $081A, $0830:
      begin
        if Func = $0817 then k := 0 else if Func = $0830 then k := 1 else k := 2;
        P.ArcEx(S16(D, q + 14), S16(D, q + 12), S16(D, q + 10), S16(D, q + 8),
          S16(D, q + 6), S16(D, q + 4), S16(D, q + 2), S16(D, q), k);
      end;
    $041F: P.SetPixel(S16(D, q + 6), S16(D, q + 4), ColorAt(D, q));
    $0416: P.ClipIntersect(P.RectPath(S16(D, q + 6), S16(D, q + 4), S16(D, q + 2), S16(D, q)), frNonZero);
    $0415: P.ClipExclude(P.RectPath(S16(D, q + 6), S16(D, q + 4), S16(D, q + 2), S16(D, q)));
    $012C: begin
             k := U16(D, q);
             if (k <= High(P.Objects)) and (P.Objects[k].Kind = goRegion) then P.ClipReplace(P.Objects[k].Region, frNonZero)
             else P.ClipReset;
           end;
    $0220: P.ClipOffset(S16(D, q + 2), S16(D, q));
    $0228: begin   // FILLREGION region, brush
             k := U16(D, q);
             i := U16(D, q + 2);
             if (k <= High(P.Objects)) and (P.Objects[k].Kind = goRegion) and (i <= High(P.Objects)) and
                (P.Objects[i].Kind = goBrush) then P.FillDevicePath(P.Objects[k].Region, P.Objects[i].Brush, frNonZero);
           end;
    $012B: begin   // PAINTREGION
             k := U16(D, q);
             if (k <= High(P.Objects)) and (P.Objects[k].Kind = goRegion) then
               P.FillDevicePath(P.Objects[k].Region, P.S.Brush, frNonZero);
           end;
    $0429: begin   // FRAMEREGION region, brush, height, width
             k := U16(D, q);
             i := U16(D, q + 2);
             if (k <= High(P.Objects)) and (P.Objects[k].Kind = goRegion) and (i <= High(P.Objects)) and
                (P.Objects[i].Kind = goBrush) then
               P.FrameDevicePath(P.Objects[k].Region, P.Objects[i].Brush, P.MapLen(Max(1, S16(D, q + 6))));
           end;
    $0521: Text(q, Len, False);
    $0A32: Text(q, Len, True);
    $061D: begin   // PATBLT rop, height, width, y, x
             rop := Integer(U32(D, q));
             b := P.S.Brush;
             if rop = $00000042 then begin b.Style := 0; b.Color := XV_BLACK; end
             else if rop = $00FF0062 then begin b.Style := 0; b.Color := XV_WHITE; end
             else if rop = $00550009 then Exit;          // DSTINVERT: nothing sensible
             P.FillRect(S16(D, q + 10), S16(D, q + 8), S16(D, q + 10) + S16(D, q + 6), S16(D, q + 8) + S16(D, q + 4), b);
           end;
    $0B41, $0940:  // DIBSTRETCHBLT / DIBBITBLT
      begin
        rop := Integer(U32(D, q));
        if Func = $0B41 then dibOfs := q + 20 else dibOfs := q + 16;
        if dibOfs + 40 > q + Len then
        begin
          // without a bitmap: a pattern blit (one more word in the record)
          if Func = $0B41 then
            P.FillRect(S16(D, q + 16), S16(D, q + 14), S16(D, q + 16) + S16(D, q + 12), S16(D, q + 14) + S16(D, q + 10), P.S.Brush)
          else
            P.FillRect(S16(D, q + 14), S16(D, q + 12), S16(D, q + 14) + S16(D, q + 10), S16(D, q + 12) + S16(D, q + 8), P.S.Brush);
          Exit;
        end;
        if not XVDecodeDIB(D, dibOfs, q + Len - dibOfs, -1, q + Len - dibOfs, img) then Exit;
        if Func = $0B41 then
          P.DrawImage(img, S16(D, q + 18), S16(D, q + 16), S16(D, q + 14), S16(D, q + 12),
            S16(D, q + 10), S16(D, q + 8), S16(D, q + 6), S16(D, q + 4), rop)
        else
          P.DrawImage(img, S16(D, q + 14), S16(D, q + 12), S16(D, q + 10), S16(D, q + 8),
            S16(D, q + 6), S16(D, q + 4), S16(D, q + 10), S16(D, q + 8), rop);
      end;
    $0F43:         // STRETCHDIB rop, usage, srcH, srcW, ySrc, xSrc, dstH, dstW, yDst, xDst, DIB
      begin
        rop := Integer(U32(D, q));
        dibOfs := q + 22;
        if not XVDecodeDIB(D, dibOfs, q + Len - dibOfs, -1, q + Len - dibOfs, img) then Exit;
        P.DrawImage(img, S16(D, q + 20), S16(D, q + 18), S16(D, q + 16), S16(D, q + 14),
          S16(D, q + 12), img.H - S16(D, q + 10) - S16(D, q + 6), S16(D, q + 8), S16(D, q + 6), rop);
      end;
    $0D33:         // SETDIBTODEV usage, scans, start, ySrc, xSrc, h, w, yDst, xDst, DIB
      begin
        dibOfs := q + 18;
        if not XVDecodeDIB(D, dibOfs, q + Len - dibOfs, -1, q + Len - dibOfs, img) then Exit;
        P.DrawImage(img, S16(D, q + 16), S16(D, q + 14), S16(D, q + 12), S16(D, q + 10),
          S16(D, q + 8), S16(D, q + 6), S16(D, q + 12), S16(D, q + 10), $00CC0020);
      end;
    $0922, $0B23:  // BITBLT / STRETCHBLT with device dependent bitmaps: pattern blits only
      begin
        if Func = $0B23 then
          P.FillRect(S16(D, q + 16), S16(D, q + 14), S16(D, q + 16) + S16(D, q + 12), S16(D, q + 14) + S16(D, q + 10), P.S.Brush)
        else
          P.FillRect(S16(D, q + 14), S16(D, q + 12), S16(D, q + 14) + S16(D, q + 10), S16(D, q + 12) + S16(D, q + 8), P.S.Brush);
      end;
  end;
end;

procedure TWmfReader.Run;
var
  q, hs, size, func, ver: Integer;
  placeable: Boolean;
  bx1, by1, bx2, by2, inch: Integer;
  w, h, ex, ey: Double;
begin
  P.IsWMF := True;
  placeable := U32(D, 0) = $9AC6CDD7;
  q := 0;
  bx1 := 0; by1 := 0; bx2 := 0; by2 := 0; inch := 0;
  if placeable then
  begin
    bx1 := S16(D, 6); by1 := S16(D, 8); bx2 := S16(D, 10); by2 := S16(D, 12);
    inch := U16(D, 14);
    q := 22;
    // the player starts with the window at the bounding box
    P.S.MapMode := 8;
    P.S.WinOrgX := Min(bx1, bx2); P.S.WinOrgY := Min(by1, by2);
    P.S.WinExtX := Max(1, Abs(bx2 - bx1)); P.S.WinExtY := Max(1, Abs(by2 - by1));
    P.WmfVpX := P.S.WinExtX; P.WmfVpY := P.S.WinExtY;
    P.SetMapMode(8);
  end;
  hs := U16(D, q + 2) * 2;
  ver := U16(D, q + 4);
  if (hs < 18) or (ver = 0) then hs := 18;
  Inc(q, hs);
  while q + 6 <= Length(D) do
  begin
    size := Integer(U32(D, q)) * 2;
    func := U16(D, q + 4);
    if func = 0 then Break;
    if (size < 6) or (q + size > Length(D)) then size := Length(D) - q;
    try
      Record_(func, q + 6, size - 6);
    except
      // a damaged record is skipped
    end;
    Inc(q, size);
  end;
  // picture rectangle and size
  if placeable then
  begin
    ex := Abs(bx2 - bx1); ey := Abs(by2 - by1);
    if inch <= 0 then inch := 1440;
    w := ex / inch * 96; h := ey / inch * 96;
    Doc.Width := Max(w, 1); Doc.Height := Max(h, 1);
    Doc.ViewBox := XVRect(0, 0, Max(ex, 1), Max(ey, 1));
  end
  else
  begin
    ex := P.WmfVpX; ey := P.WmfVpY;
    if (ex <= 1) or (ey <= 1) then
    begin
      if P.HaveBounds then
      begin
        Doc.ViewBox := P.Bounds;
        ex := P.Bounds.Width; ey := P.Bounds.Height;
      end
      else begin ex := 100; ey := 100; Doc.ViewBox := XVRect(0, 0, 100, 100); end;
    end
    else Doc.ViewBox := XVRect(0, 0, ex, ey);
    // large extents are usually 0.01 mm (METAFILEPICT in MM_HIMETRIC)
    if Max(ex, ey) > 3000 then begin w := ex / 100 / 25.4 * 96; h := ey / 100 / 25.4 * 96; end
    else begin w := ex; h := ey; end;
    Doc.Width := Max(w, 1); Doc.Height := Max(h, 1);
  end;
  P.Finish;
end;

procedure XVReadWMFDoc(Doc: TXVDocument; const Data: TBytes);
var R: TWmfReader;
begin
  R := TWmfReader.Create;
  try
    R.D := Data;
    R.Doc := Doc;
    R.P := TXVGdiPlayer.Create(Doc);
    try
      R.Run;
    finally
      R.P.Free;
    end;
  finally
    R.Free;
  end;
end;

initialization
  XVRegisterReader('WMF', 'wmf;apm', XVIsWMF, XVReadWMFDoc);
end.
