unit XVReadEMF;

{$mode delphi}{$H+}
{$R-}{$Q-}

// XelVectors - Enhanced Metafile (EMF) reader: the records are played on the
// GDI emulator (XVGdiPlay). Document space is the reference device of the
// metafile; the picture is its frame rectangle.

interface

uses
  SysUtils, Classes, Math, XVModel, XVImageCodec, XVGdiPlay;

function XVIsEMF(const Data: TBytes): Boolean;
procedure XVReadEMFDoc(Doc: TXVDocument; const Data: TBytes);

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

function S32(const D: TBytes; p: Integer): Integer; inline;
begin
  Result := Integer(U32(D, p));
end;

function F32(const D: TBytes; p: Integer): Double;
var c: Cardinal; s: Single;
begin
  c := U32(D, p);
  Move(c, s, 4);
  Result := s;
  if IsNan(Result) or IsInfinite(Result) then Result := 0;
end;

function ColorAt(const D: TBytes; p: Integer): TXVColor;
begin
  Result := XVBGRToColor(U32(D, p) and $FFFFFF);
end;

function XVIsEMF(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) >= 88) and (U32(Data, 0) = 1) and (U32(Data, 40) = $464D4520);
end;

type
  TEmfReader = class
    D: TBytes;
    P: TXVGdiPlayer;
    Doc: TXVDocument;
    function XForm(q: Integer): TXVMatrix;
    function Pts32(q, N: Integer): TXVPoints;
    function Pts16(q, N: Integer): TXVPoints;
    function RegionPath(q, Len: Integer; Logical: Boolean): TXVPath;
    function Dib(Rec, OffBmi, CbBmi, OffBits, CbBits: Integer; out Img: TXVImage): Boolean;
    procedure TextRec(q, Rec: Integer; Wide: Boolean);
    procedure Record_(T, Rec, Size: Integer);
    procedure Run;
  end;

function TEmfReader.XForm(q: Integer): TXVMatrix;
begin
  Result := TXVMatrix.Make(F32(D, q), F32(D, q + 4), F32(D, q + 8), F32(D, q + 12), F32(D, q + 16), F32(D, q + 20));
end;

function TEmfReader.Pts32(q, N: Integer): TXVPoints;
var i: Integer;
begin
  N := Max(0, Min(N, (Length(D) - q) div 8));
  SetLength(Result, N);
  for i := 0 to N - 1 do
  begin
    Result[i].X := S32(D, q + 8 * i);
    Result[i].Y := S32(D, q + 8 * i + 4);
  end;
end;

function TEmfReader.Pts16(q, N: Integer): TXVPoints;
var i: Integer;
begin
  N := Max(0, Min(N, (Length(D) - q) div 4));
  SetLength(Result, N);
  for i := 0 to N - 1 do
  begin
    Result[i].X := S16(D, q + 4 * i);
    Result[i].Y := S16(D, q + 4 * i + 2);
  end;
end;

// RGNDATA: header (size 32, type, count, size, bounds) and rectangles
function TEmfReader.RegionPath(q, Len: Integer; Logical: Boolean): TXVPath;
var
  n, i, k: Integer;
  x1, y1, x2, y2: Double;
  pts: array[0..3] of TXVPoint;
begin
  Result := Default(TXVPath);
  Result.Clear;
  if Len < 32 then Exit;
  n := U32(D, q + 8);
  k := q + Integer(U32(D, q));
  for i := 0 to n - 1 do
  begin
    if k + 16 > q + Len then Break;
    x1 := S32(D, k); y1 := S32(D, k + 4); x2 := S32(D, k + 8); y2 := S32(D, k + 12);
    if Logical then
    begin
      pts[0] := P.Map(x1, y1); pts[1] := P.Map(x2, y1); pts[2] := P.Map(x2, y2); pts[3] := P.Map(x1, y2);
    end
    else
    begin
      pts[0] := XVPt(x1, y1); pts[1] := XVPt(x2, y1); pts[2] := XVPt(x2, y2); pts[3] := XVPt(x1, y2);
    end;
    Result.AddPolygon(pts, True);
    Inc(k, 16);
  end;
end;

function TEmfReader.Dib(Rec, OffBmi, CbBmi, OffBits, CbBits: Integer; out Img: TXVImage): Boolean;
begin
  Result := False;
  Img.W := 0; Img.H := 0; Img.Px := nil;
  if (CbBmi < 12) or (OffBmi <= 0) then Exit;
  Result := XVDecodeDIB(D, Rec + OffBmi, CbBmi, Rec + OffBits, CbBits, Img);
end;

procedure TEmfReader.TextRec(q, Rec: Integer; Wide: Boolean);
var
  x, y, n, offStr, opts, offDx, i, cp: Integer;
  r: TXVRect;
  s: string;
  dx: array of Double;
  chars: TStringArray;
  u, k: Integer;
  ws: UnicodeString;
begin
  // EMRTEXT
  x := S32(D, q); y := S32(D, q + 4);
  n := U32(D, q + 8);
  offStr := U32(D, q + 12);
  opts := U32(D, q + 16);
  r := XVRect(S32(D, q + 20), S32(D, q + 24), S32(D, q + 28), S32(D, q + 32));
  offDx := U32(D, q + 36);
  if (n < 0) or (n > 100000) then Exit;
  if Wide then
  begin
    n := Min(n, Max(0, (Length(D) - (Rec + offStr)) div 2));
    s := XVUtf16ToUtf8(D, Rec + offStr, n * 2);
  end
  else
  begin
    cp := XVCharsetCodePage(P.S.Font.CharSet);
    if P.S.Font.CharSet = 2 then cp := 0;
    n := Min(n, Max(0, Length(D) - (Rec + offStr)));
    s := XVCodePageToUtf8(D, Rec + offStr, n, cp);
  end;
  // symbol fonts write their glyphs in the private area F0xx
  if (s <> '') and (Pos(#$EF#$80, s) > 0) then
  begin
    ws := UTF8Decode(s);
    for i := 1 to Length(ws) do
      if (Ord(ws[i]) >= $F020) and (Ord(ws[i]) <= $F0FF) then ws[i] := WideChar(Ord(ws[i]) - $F000);
    s := UTF8Encode(ws);
  end;
  dx := nil;
  if (offDx > 0) and (Rec + offDx + 4 * n <= Length(D)) then
  begin
    chars := XVUtf8Chars(s);
    SetLength(dx, Length(chars));
    // one entry per UTF-16 unit (or byte); with ETO_PDY two per unit
    k := 0;
    for i := 0 to High(chars) do
    begin
      if Wide then u := Length(UTF8Decode(chars[i])) else u := 1;
      dx[i] := 0;
      while (u > 0) and (k < n) do
      begin
        if (opts and $2000) <> 0 then dx[i] := dx[i] + S32(D, Rec + offDx + 8 * k)
        else dx[i] := dx[i] + S32(D, Rec + offDx + 4 * k);
        Inc(k);
        Dec(u);
      end;
    end;
  end;
  P.TextOut(x, y, s, dx, opts, r, (opts and 6) <> 0);
end;

procedure TEmfReader.Record_(T, Rec, Size: Integer);
var
  q, n, i, k, total, rop, mode: Integer;
  counts: array of Integer;
  pts: TXVPoints;
  O: TGdiObj;
  img: TXVImage;
  b: TGdiBrush;
  path: TXVPath;
  ml: Cardinal;
  types: array of Byte;
  alpha, a: Cardinal;
  op: Double;
  x1, y1, x2, y2: Double;
  g: TXVGradient;
  c1, c2: TXVColor;
  v1, v2: Integer;
  gp: TXVPath;
  gi: Integer;

  function VertColor(Idx: Integer): TXVColor;
  var vq: Integer;
  begin
    vq := q + 16 + Idx * 16;
    Result := XVRGB(U16(D, vq + 8) shr 8, U16(D, vq + 10) shr 8, U16(D, vq + 12) shr 8);
  end;

begin
  q := Rec + 8;
  case T of
    // ---- state ----
    9: P.SetWindowExt(S32(D, q), S32(D, q + 4));
    10: P.SetWindowOrg(S32(D, q), S32(D, q + 4));
    11: P.SetViewportExt(S32(D, q), S32(D, q + 4));
    12: P.SetViewportOrg(S32(D, q), S32(D, q + 4));
    17: P.SetMapMode(U32(D, q));
    18: P.S.BkMode := U32(D, q);
    19: P.S.FillMode := U32(D, q);
    20: P.S.Rop2 := U32(D, q);
    22: P.S.TextAlign := U32(D, q);
    24: P.S.TextColor := ColorAt(D, q);
    25: P.S.BkColor := ColorAt(D, q);
    27: P.MoveTo(S32(D, q), S32(D, q + 4));
    31: P.ScaleViewportExt(S32(D, q), S32(D, q + 4), S32(D, q + 8), S32(D, q + 12));
    32: P.ScaleWindowExt(S32(D, q), S32(D, q + 4), S32(D, q + 8), S32(D, q + 12));
    33: P.SaveDC;
    34: P.RestoreDC(S32(D, q));
    35: P.SetWorld(XForm(q));
    36: P.ModifyWorld(XForm(q), U32(D, q + 24));
    57: P.S.ArcDir := U32(D, q);
    58: begin
          ml := U32(D, q);
          if ml > 100000 then P.S.MiterLimit := F32(D, q) else P.S.MiterLimit := ml;
        end;
    // ---- objects ----
    37: P.SelectObject(U32(D, q));
    40: P.DeleteObject(U32(D, q));
    38: begin   // CREATEPEN: ihPen, style, width (POINTL), color
          O := Default(TGdiObj);
          O.Kind := goPen;
          O.Pen.Style := U32(D, q + 4);
          O.Pen.Width := S32(D, q + 8);
          O.Pen.Color := ColorAt(D, q + 16);
          O.Pen.Cosmetic := O.Pen.Width <= 1;
          O.Pen.BrushImage := -1;
          P.SetObject(U32(D, q), O);
        end;
    95: begin   // EXTCREATEPEN: ihPen, offBmi, cbBmi, offBits, cbBits, style, width, brush style, color, hatch, n, entries
          O := Default(TGdiObj);
          O.Kind := goPen;
          O.Pen.Style := U32(D, q + 20);
          O.Pen.Width := U32(D, q + 24);
          O.Pen.Color := ColorAt(D, q + 32);
          O.Pen.Cosmetic := (O.Pen.Style and $00010000) = 0;
          O.Pen.BrushImage := -1;
          if U32(D, q + 28) = 1 then O.Pen.Style := (O.Pen.Style and not $0F) or 5;   // BS_NULL
          n := U32(D, q + 40);
          if (n > 0) and (n < 64) then
          begin
            SetLength(O.Pen.Dashes, n);
            for i := 0 to n - 1 do O.Pen.Dashes[i] := U32(D, q + 44 + 4 * i);
          end;
          P.SetObject(U32(D, q), O);
        end;
    39: begin   // CREATEBRUSHINDIRECT
          O := Default(TGdiObj);
          O.Kind := goBrush;
          O.Brush.Style := U32(D, q + 4);
          O.Brush.Color := ColorAt(D, q + 8);
          O.Brush.Hatch := U32(D, q + 12);
          O.Brush.Image := -1;
          if O.Brush.Style in [3, 5, 6] then O.Brush.Style := 0;
          P.SetObject(U32(D, q), O);
        end;
    93, 94: begin   // CREATEMONOBRUSH / CREATEDIBPATTERNBRUSHPT: ih, usage, offBmi, cbBmi, offBits, cbBits
          O := Default(TGdiObj);
          O.Kind := goBrush;
          O.Brush.Image := -1;
          O.Brush.Style := 0;
          O.Brush.Color := XVRGB($80, $80, $80);
          if Dib(Rec, U32(D, q + 8), U32(D, q + 12), U32(D, q + 16), U32(D, q + 20), img) then
          begin
            if T = 93 then
              // monochrome: 0 = text colour, 1 = background colour
              for i := 0 to High(img.Px) do
                if (img.Px[i] and $FFFFFF) = 0 then img.Px[i] := P.S.TextColor else img.Px[i] := P.S.BkColor;
            O.Brush.Image := Doc.AddImageData(img);
            O.Brush.Style := 5;
            O.Brush.Color := XVImageAverage(img);
          end;
          P.SetObject(U32(D, q), O);
        end;
    82: begin   // EXTCREATEFONTINDIRECTW: ihFont, LOGFONTW
          O := Default(TGdiObj);
          O.Kind := goFont;
          O.Font.Height := S32(D, q + 4);
          O.Font.Width := S32(D, q + 8);
          O.Font.Escapement := S32(D, q + 12);
          O.Font.Orientation := S32(D, q + 16);
          O.Font.Weight := S32(D, q + 20);
          if q + 32 <= Length(D) then
          begin
            O.Font.Italic := D[q + 24] <> 0;
            O.Font.Underline := D[q + 25] <> 0;
            O.Font.Strike := D[q + 26] <> 0;
            O.Font.CharSet := D[q + 27];
          end;
          n := 0;
          while (n < 32) and (U16(D, q + 32 + 2 * n) <> 0) do Inc(n);
          O.Font.Face := Trim(XVUtf16ToUtf8(D, q + 32, 2 * n));
          P.SetObject(U32(D, q), O);
        end;
    49: begin O := Default(TGdiObj); O.Kind := goPalette; P.SetObject(U32(D, q), O); end;
    99, 122: begin O := Default(TGdiObj); O.Kind := goOther; P.SetObject(U32(D, q), O); end;
    // ---- clipping ----
    26: P.ClipOffset(S32(D, q), S32(D, q + 4));
    29: P.ClipExclude(P.RectPath(S32(D, q), S32(D, q + 4), S32(D, q + 8), S32(D, q + 12)));
    30: P.ClipIntersect(P.RectPath(S32(D, q), S32(D, q + 4), S32(D, q + 8), S32(D, q + 12)), frNonZero);
    67: P.SelectClipPath(U32(D, q));
    75: begin   // EXTSELECTCLIPRGN: cbRgnData, mode, RgnData (device units)
          n := U32(D, q);
          mode := U32(D, q + 4);
          if n = 0 then
          begin
            if mode = 5 then P.ClipReset;
          end
          else
          begin
            path := RegionPath(q + 8, n, False);
            case mode of
              1: P.ClipIntersect(path, frNonZero);
              4: P.ClipExclude(path);
              2, 3: if Length(P.S.Clips) > 0 then P.ClipReplace(path, frNonZero);
            else
              P.ClipReplace(path, frNonZero);
            end;
          end;
        end;
    28: ;   // SETMETARGN
    // ---- paths ----
    59: P.BeginPath;
    60: P.EndPath;
    61: P.CloseFigure;
    62: P.FillPath;
    63: P.StrokeAndFillPath;
    64: P.StrokePath;
    65: ;   // FLATTENPATH
    66: P.WidenPath;
    68: P.AbortPath;
    // ---- drawing ----
    2, 3, 4, 5, 6, 85, 86, 87, 88, 89:
      begin
        n := U32(D, q + 16);
        if T >= 85 then pts := Pts16(q + 20, n) else pts := Pts32(q + 20, n);
        case T of
          2, 85: P.PolyBezier(pts, False);
          3, 86: P.Polygon(pts);
          4, 87: P.Polyline(pts, False);
          5, 88: P.PolyBezier(pts, True);
          6, 89: P.Polyline(pts, True);
        end;
      end;
    7, 8, 90, 91:
      begin
        n := U32(D, q + 16);
        total := U32(D, q + 20);
        if (n < 0) or (n > 1000000) then Exit;
        SetLength(counts, n);
        for i := 0 to n - 1 do counts[i] := U32(D, q + 24 + 4 * i);
        if T >= 90 then pts := Pts16(q + 24 + 4 * n, total) else pts := Pts32(q + 24 + 4 * n, total);
        if T in [8, 91] then P.PolyPolygon(pts, counts) else P.PolyPolyline(pts, counts);
      end;
    56, 92:
      begin
        n := U32(D, q + 16);
        if T = 92 then pts := Pts16(q + 20, n) else pts := Pts32(q + 20, n);
        SetLength(types, Length(pts));
        if T = 92 then k := q + 20 + 4 * n else k := q + 20 + 8 * n;
        for i := 0 to High(types) do if k + i < Length(D) then types[i] := D[k + i];
        P.PolyDraw(pts, types);
      end;
    54: P.LineTo(S32(D, q), S32(D, q + 4));
    42: P.Ellipse(S32(D, q), S32(D, q + 4), S32(D, q + 8), S32(D, q + 12));
    43: P.Rectangle(S32(D, q), S32(D, q + 4), S32(D, q + 8), S32(D, q + 12));
    44: P.RoundRect(S32(D, q), S32(D, q + 4), S32(D, q + 8), S32(D, q + 12), S32(D, q + 16), S32(D, q + 20));
    45, 46, 47, 55:
      begin
        case T of
          45: k := 0;
          46: k := 1;
          47: k := 2;
        else
          k := 3;
        end;
        P.ArcEx(S32(D, q), S32(D, q + 4), S32(D, q + 8), S32(D, q + 12), S32(D, q + 16), S32(D, q + 20),
          S32(D, q + 24), S32(D, q + 28), k);
      end;
    41: P.AngleArc(S32(D, q), S32(D, q + 4), U32(D, q + 8), F32(D, q + 12), F32(D, q + 16));
    15: P.SetPixel(S32(D, q), S32(D, q + 4), ColorAt(D, q + 8));
    71: begin   // FILLRGN: bounds, cbRgnData, ihBrush, RgnData
          n := U32(D, q + 16);
          k := U32(D, q + 20);
          if (k <= High(P.Objects)) and (P.Objects[k].Kind = goBrush) then b := P.Objects[k].Brush
          else if (Cardinal(k) and $80000000) <> 0 then begin b := P.S.Brush; end
          else Exit;
          P.FillDevicePath(RegionPath(q + 24, n, True), b, frNonZero);
        end;
    72: begin   // FRAMERGN: bounds, cbRgnData, ihBrush, width, height, RgnData
          n := U32(D, q + 16);
          k := U32(D, q + 20);
          if (k <= High(P.Objects)) and (P.Objects[k].Kind = goBrush) then
            P.FrameDevicePath(RegionPath(q + 32, n, True), P.Objects[k].Brush, P.MapLen(Max(1, S32(D, q + 24))));
        end;
    74: begin   // PAINTRGN: bounds, cbRgnData, RgnData
          n := U32(D, q + 16);
          P.FillDevicePath(RegionPath(q + 20, n, True), P.S.Brush, frNonZero);
        end;
    // ---- text ----
    84: TextRec(q + 28, Rec, True);
    83: TextRec(q + 28, Rec, False);
    96, 97:
      begin
        n := U32(D, q + 28);
        for i := 0 to Min(n, 10000) - 1 do TextRec(q + 32 + 40 * i, Rec, T = 97);
      end;
    108: begin   // SMALLTEXTOUT: x, y, cChars, options, mode, exScale, eyScale, [rect], text
          n := U32(D, q + 8);
          k := U32(D, q + 12);
          i := q + 28;
          if (k and $100) = 0 then Inc(i, 16);
          if (k and $200) <> 0 then
            P.TextOut(S32(D, q), S32(D, q + 4), XVCodePageToUtf8(D, i, n, XVCharsetCodePage(P.S.Font.CharSet)), [], k,
              XVRect(0, 0, 0, 0), False)
          else
            P.TextOut(S32(D, q), S32(D, q + 4), XVUtf16ToUtf8(D, i, 2 * n), [], k, XVRect(0, 0, 0, 0), False);
        end;
    // ---- bitmaps ----
    76, 77:  // BITBLT / STRETCHBLT
      begin
        rop := U32(D, q + 32);
        if U32(D, q + 80) = 0 then
        begin
          // no source bitmap: a pattern blit with the brush
          b := P.S.Brush;
          if rop = $00000042 then begin b.Style := 0; b.Color := XV_BLACK; end
          else if rop = $00FF0062 then begin b.Style := 0; b.Color := XV_WHITE; end
          else if (rop = $00AA0029) or (rop = $00550009) then Exit;     // destination only
          P.FillRect(S32(D, q + 16), S32(D, q + 20), S32(D, q + 16) + S32(D, q + 24), S32(D, q + 20) + S32(D, q + 28), b);
          Exit;
        end;
        if not Dib(Rec, U32(D, q + 76), U32(D, q + 80), U32(D, q + 84), U32(D, q + 88), img) then Exit;
        if T = 77 then
          P.DrawImage(img, S32(D, q + 16), S32(D, q + 20), S32(D, q + 24), S32(D, q + 28),
            S32(D, q + 36), S32(D, q + 40), S32(D, q + 92), S32(D, q + 96), rop)
        else
          P.DrawImage(img, S32(D, q + 16), S32(D, q + 20), S32(D, q + 24), S32(D, q + 28),
            S32(D, q + 36), S32(D, q + 40), S32(D, q + 24), S32(D, q + 28), rop);
      end;
    81:      // STRETCHDIBITS
      begin
        rop := U32(D, q + 60);
        if not Dib(Rec, U32(D, q + 40), U32(D, q + 44), U32(D, q + 48), U32(D, q + 52), img) then Exit;
        // the source rectangle of a bottom-up DIB counts from its last row
        n := Abs(S32(D, q + 36));
        P.DrawImage(img, S32(D, q + 16), S32(D, q + 20), S32(D, q + 64), S32(D, q + 68),
          S32(D, q + 24), img.H - S32(D, q + 28) - n, Abs(S32(D, q + 32)), n, rop);
      end;
    80:      // SETDIBITSTODEVICE
      begin
        if not Dib(Rec, U32(D, q + 40), U32(D, q + 44), U32(D, q + 48), U32(D, q + 52), img) then Exit;
        n := Abs(S32(D, q + 36));
        P.DrawImage(img, S32(D, q + 16), S32(D, q + 20), S32(D, q + 32), n,
          S32(D, q + 24), img.H - S32(D, q + 28) - n, S32(D, q + 32), n, $00CC0020);
      end;
    114, 116:  // ALPHABLEND / TRANSPARENTBLT
      begin
        if not Dib(Rec, U32(D, q + 76), U32(D, q + 80), U32(D, q + 84), U32(D, q + 88), img) then Exit;
        alpha := U32(D, q + 32);
        op := 1;
        if T = 114 then
        begin
          op := ((alpha shr 16) and $FF) / 255;
          if ((alpha shr 24) and 1) <> 0 then
          begin
            // premultiplied source alpha
            for i := 0 to High(img.Px) do
            begin
              a := img.Px[i] shr 24;
              if (a > 0) and (a < 255) then
                img.Px[i] := (a shl 24) or (Min(255, ((img.Px[i] shr 16) and $FF) * 255 div a) shl 16) or
                  (Min(255, ((img.Px[i] shr 8) and $FF) * 255 div a) shl 8) or Min(255, (img.Px[i] and $FF) * 255 div a);
            end;
          end
          else
            for i := 0 to High(img.Px) do img.Px[i] := img.Px[i] or $FF000000;
        end
        else
        begin
          // the transparent colour
          c1 := XVBGRToColor(alpha and $FFFFFF);
          for i := 0 to High(img.Px) do
            if (img.Px[i] or $FF000000) = c1 then img.Px[i] := 0 else img.Px[i] := img.Px[i] or $FF000000;
        end;
        k := Doc.Count;
        P.DrawImage(img, S32(D, q + 16), S32(D, q + 20), S32(D, q + 24), S32(D, q + 28),
          S32(D, q + 36), S32(D, q + 40), S32(D, q + 92), S32(D, q + 96), $00CC0020);
        if (op < 1) and (Doc.Count > k) and (Doc.Elements[Doc.Count - 1].Kind = ekImage) then
          Doc.Elements[Doc.Count - 1].Opacity := op;
      end;
    118:     // GRADIENTFILL: bounds, nVer, nTri, mode, vertices, meshes
      begin
        n := U32(D, q + 16);
        k := U32(D, q + 20);
        mode := U32(D, q + 24);
        q := q + 12;    // vertices start at q + 16 for VertColor
        for i := 0 to k - 1 do
        begin
          if mode in [0, 1] then
          begin
            v1 := U32(D, q + 16 + n * 16 + 8 * i);
            v2 := U32(D, q + 16 + n * 16 + 8 * i + 4);
            if (v1 >= n) or (v2 >= n) then Continue;
            x1 := S32(D, q + 16 + v1 * 16); y1 := S32(D, q + 16 + v1 * 16 + 4);
            x2 := S32(D, q + 16 + v2 * 16); y2 := S32(D, q + 16 + v2 * 16 + 4);
            c1 := VertColor(v1); c2 := VertColor(v2);
            g := Default(TXVGradient);
            g.Kind := gkLinear;
            g.Matrix := TXVMatrix.Identity;
            if mode = 0 then begin g.X1 := x1; g.Y1 := y1; g.X2 := x2; g.Y2 := y1; end
            else begin g.X1 := x1; g.Y1 := y1; g.X2 := x1; g.Y2 := y2; end;
            g.Matrix := P.Total;
            SetLength(g.Stops, 2);
            g.Stops[0].Offset := 0; g.Stops[0].Color := c1;
            g.Stops[1].Offset := 1; g.Stops[1].Color := c2;
            gi := Doc.AddGradient(g);
            gp := P.RectPath(x1, y1, x2, y2);
            P.SyncClip;
            Doc.AddPath(gp, XVGradientPaint(gi, XVLerpColor(c1, c2, 0.5)), XVNoStroke, frNonZero);
          end
          else
          begin
            // triangles: their average colour
            v1 := U32(D, q + 16 + n * 16 + 12 * i);
            if v1 >= n then Continue;
            SetLength(pts, 3);
            for v2 := 0 to 2 do
            begin
              total := U32(D, q + 16 + n * 16 + 12 * i + 4 * v2);
              if total >= n then total := 0;
              pts[v2] := P.Map(S32(D, q + 16 + total * 16), S32(D, q + 16 + total * 16 + 4));
            end;
            gp := Default(TXVPath);
            gp.Clear;
            gp.AddPolygon(pts, True);
            c1 := XVLerpColor(XVLerpColor(VertColor(U32(D, q + 16 + n * 16 + 12 * i)),
              VertColor(U32(D, q + 16 + n * 16 + 12 * i + 4)), 0.5), VertColor(U32(D, q + 16 + n * 16 + 12 * i + 8)), 1 / 3);
            P.SyncClip;
            Doc.AddPath(gp, XVSolid(c1), XVNoStroke, frNonZero);
          end;
        end;
      end;
  end;
end;

procedure TEmfReader.Run;
var
  q, t, size, cnt: Integer;
  fl, ft, fr, fb, bl, bt, br, bb: Integer;
  devX, devY, mmX, mmY, umX, umY: Integer;
  pxmmX, pxmmY: Double;
  vb: TXVRect;
begin
  bl := S32(D, 8); bt := S32(D, 12); br := S32(D, 16); bb := S32(D, 20);
  fl := S32(D, 24); ft := S32(D, 28); fr := S32(D, 32); fb := S32(D, 36);
  devX := S32(D, 72); devY := S32(D, 76);
  mmX := S32(D, 80); mmY := S32(D, 84);
  pxmmX := 96 / 25.4; pxmmY := 96 / 25.4;
  if (mmX > 0) and (mmY > 0) and (devX > 0) and (devY > 0) then
  begin
    pxmmX := devX / mmX; pxmmY := devY / mmY;
    // the exact size in micrometres (extension 2)
    if U32(D, 4) >= 108 then
    begin
      umX := S32(D, 100); umY := S32(D, 104);
      if (umX > 0) and (umY > 0) and (Abs(umX / 1000 - mmX) < 2) then
      begin
        pxmmX := devX / (umX / 1000); pxmmY := devY / (umY / 1000);
      end;
    end;
  end;
  P.DevPxPerMMX := pxmmX;
  P.DevPxPerMMY := pxmmY;
  P.SetMapMode(1);
  q := 0;
  cnt := 0;
  while q + 8 <= Length(D) do
  begin
    t := U32(D, q);
    size := U32(D, q + 4);
    if (size < 8) or (q + size > Length(D)) then size := Length(D) - q;
    if t = 14 then Break;                  // EMR_EOF
    if t <> 1 then
      try
        Record_(t, q, size);
      except
        // a damaged record is skipped
      end;
    Inc(q, (size + 3) and not 3);
    Inc(cnt);
    if cnt > 50000000 then Break;
  end;
  // the frame (0.01 mm) in device units; the bounds when it is missing
  if (fr > fl) and (fb > ft) then
  begin
    vb := XVRect(fl / 100 * pxmmX, ft / 100 * pxmmY, fr / 100 * pxmmX, fb / 100 * pxmmY);
    Doc.Width := (fr - fl) / 100 / 25.4 * 96;
    Doc.Height := (fb - ft) / 100 / 25.4 * 96;
  end
  else if (br > bl) and (bb > bt) then
  begin
    vb := XVRect(bl, bt, br + 1, bb + 1);
    Doc.Width := (br - bl + 1) / pxmmX / 25.4 * 96;
    Doc.Height := (bb - bt + 1) / pxmmY / 25.4 * 96;
  end
  else if P.HaveBounds then
  begin
    vb := P.Bounds;
    Doc.Width := vb.Width / pxmmX / 25.4 * 96;
    Doc.Height := vb.Height / pxmmY / 25.4 * 96;
  end
  else
  begin
    vb := XVRect(0, 0, 100, 100);
    Doc.Width := 100; Doc.Height := 100;
  end;
  Doc.ViewBox := vb;
  P.Finish;
end;

procedure XVReadEMFDoc(Doc: TXVDocument; const Data: TBytes);
var R: TEmfReader;
begin
  R := TEmfReader.Create;
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
  XVRegisterReader('EMF', 'emf;emz', XVIsEMF, XVReadEMFDoc);
end.
