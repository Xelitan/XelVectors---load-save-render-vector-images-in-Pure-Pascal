// XVReadCDR: the page painter, the RIFF walk and the entry points.

type
  TCardArr = array of Cardinal;
  TChunkProc = procedure(const FourCC: AnsiString; const B: TBytes; Pos, Len, Level: Integer) of object;
  TListProc = procedure(const ListType: AnsiString; Level: Integer; Start: Boolean) of object;

  TClipEntry = record
    Level: Integer;
    Clip: Integer;              // clip index, -1 none
    ContA, ContB: Integer;      // the container's own elements, drawn below its contents
  end;

  { TCdrPainter }

  TCdrPainter = class
  private
    Doc: TCdrDoc;
    Out: TXVDocument;
    Items: array of TOutItem;
    FImgKeys: TStringList;      // fill image key -> document image index
    FBmpImg: TDictionary<Cardinal, Integer>;
    // page state
    PageIndex: Integer;
    PageProps, IgnorePage, PageDone, DrawPage: Boolean;
    PageLevel, VectLevel: Integer;
    PageItemStart, PageElemStart, PageObjs: Integer;
    Spnd: Cardinal;
    Clips: array of TClipEntry;
    // object state
    ObjActive: Boolean;
    ObjLevel: Integer;
    Path: TPath;
    Fill: TCdrFill;
    Outl: TCdrOutl;
    StyleId: Cardinal;
    Trafo: TMats;
    Opacity: Double;
    HasBmp: Boolean;
    BmpId: Cardinal;
    BmpX1, BmpY1, BmpX2, BmpY2: Double;
    TextKind: Integer;          // 0 none, 1 artistic, 2 paragraph
    TextX, TextY, TextW, TextH: Double;
    TextId: Cardinal;
    IsPolygon, HasPolyTrafo, IsSpline: Boolean;
    PolyNum, PolyNext: Cardinal;
    PolyRx, PolyRy, PolyCx, PolyCy: Double;
    SplPts: array of Double;
    SplKnots: TCardArr;
    procedure AddItem(K: TOutKind; A, B, Clip: Integer);
    // geometry
    procedure PMove(x, y: Double);
    procedure PLine(x, y: Double);
    procedure PCubic(x1, y1, x2, y2, x, y: Double);
    procedure PQuad(x1, y1, x, y: Double);
    procedure PClose;
    procedure ProcessPoints(const Pts: array of Double; const Types: TBytes);
    procedure ReadPoints(var R: TRd; Count: Integer);
    procedure ReadRectangle(var R: TRd);
    procedure ReadEllipse(var R: TRd);
    procedure ReadBitmapObj(var R: TRd);
    procedure ReadLoda(var R: TRd);
    procedure ReadTrfd(var R: TRd);
    procedure ReadOpacity(var R: TRd);
    procedure ReadPpdt(var R: TRd);
    procedure MakePolygon;
    procedure MakeSpline;
    procedure Apply(var x, y: Double);
    function Det: Double;
    procedure MapPt(x, y: Double; out ox, oy: Double);
    function BuildPath(out Empty: Boolean; out MinX, MinY, MaxX, MaxY: Double): TXVPath;
    // painting
    function ColorAt(const F: TCdrFill; t: Double): Cardinal;
    function FountainPaint(const F: TCdrFill; MinX, MinY, MaxX, MaxY: Double): TXVPaint;
    function PatternPaint(const F: TCdrFill; MinX, MinY, MaxX, MaxY: Double): TXVPaint;
    function MakeStroke: TXVStroke;
    procedure EmitBitmap(const P: TXVPath; PEmpty: Boolean);
    procedure EmitText;
    procedure EmitObject;
    procedure ResetObject;
  public
    SX: Double;                 // output pixels per inch
    PageW, PageH: Double;
    TargetPage, DrawnPages: Integer;
    constructor Create(ADoc: TCdrDoc; AOut: TXVDocument);
    destructor Destroy; override;
    procedure Flush;
    procedure OnChunk(const FourCC: AnsiString; const B: TBytes; Pos, Len, Level: Integer);
    procedure OnList(const ListType: AnsiString; Level: Integer; Start: Boolean);
    procedure Finish;
  end;

  { TCdrStylesPass }

  TCdrStylesPass = class
  public
    Doc: TCdrDoc;
    procedure OnChunk(const FourCC: AnsiString; const B: TBytes; Pos, Len, Level: Integer);
    procedure OnList(const ListType: AnsiString; Level: Integer; Start: Boolean);
  end;

function GetCdrVersion(c: Byte): Integer;
begin
  if c = $20 then Result := 300
  else if c < $31 then Result := 0
  else if c < $3A then Result := 100 * (c - $30)
  else if c < $41 then Result := 0
  else Result := 100 * (c - $37);
end;

function FourCCAt(const B: TBytes; p: Integer): AnsiString;
begin
  SetLength(Result, 4);
  if p + 4 <= Length(B) then
  begin
    Result[1] := AnsiChar(B[p]); Result[2] := AnsiChar(B[p + 1]);
    Result[3] := AnsiChar(B[p + 2]); Result[4] := AnsiChar(B[p + 3]);
  end
  else Result := '    ';
end;

// Walks the RIFF tree. Lengths of chunks inside compressed lists are indices
// into the list's block-length table.
procedure WalkRiff(Doc: TCdrDoc; const B: TBytes; P, E, Level: Integer; const Blocks: TCardArr;
  OnChunk: TChunkProc; OnList: TListProc);
var
  cc, lt: AnsiString;
  len, pos, cmprSize, here, k: Integer;
  ln: Cardinal;
  raw, blk: TBytes;
  bl: TCardArr;
begin
  if Level > MAX_LEVEL then Exit;
  if E > Length(B) then E := Length(B);
  while P + 8 <= E do
  begin
    if B[P] = 0 then begin Inc(P); Continue; end;
    cc := FourCCAt(B, P);
    ln := RdLE32(B, P + 4);
    if (Blocks <> nil) and (ln < Cardinal(Length(Blocks))) then ln := Blocks[ln];
    pos := P + 8;
    if ln > Cardinal(E - pos) then ln := Cardinal(Max(0, E - pos));
    len := ln;
    if (cc = 'RIFF') or (cc = 'LIST') then
    begin
      lt := FourCCAt(B, pos);
      if (cc = 'RIFF') and ((Copy(lt, 1, 3) = 'CDR') or (Copy(lt, 1, 3) = 'cdr')) then
        Doc.SetVersion(GetCdrVersion(Byte(lt[4])));
      if (lt = 'stlt') and (Doc.Version >= 700) then
        OnChunk('stlt', B, pos + 4, len - 4, Level)
      else if lt = 'cmpr' then
      begin
        // zlib-compressed list (CorelDRAW 7 .. X3)
        cmprSize := RdLE32(B, pos + 4);
        if (FourCCAt(B, pos + 20) = 'CPng') and (cmprSize > 0) and (pos + 28 + cmprSize <= pos + len) then
        begin
          // a damaged compressed list is skipped
          try
            raw := InflateZlib(@B[pos + 28], cmprSize);
            here := pos + 28 + cmprSize;
            blk := nil;
            if here < pos + len then blk := InflateZlib(@B[here], pos + len - here);
          except
            raw := nil; blk := nil;
          end;
          SetLength(bl, Length(blk) div 4);
          for k := 0 to High(bl) do bl[k] := RdLE32(blk, k * 4);
          OnList(lt, Level, True);
          WalkRiff(Doc, raw, 0, Length(raw), Level + 1, bl, OnChunk, OnList);
          OnList(lt, Level, False);
        end;
      end
      else
      begin
        OnList(lt, Level, True);
        WalkRiff(Doc, B, pos + 4, pos + len, Level + 1, Blocks, OnChunk, OnList);
        OnList(lt, Level, False);
      end;
    end
    else
      OnChunk(cc, B, pos, len, Level);
    P := pos + len;
  end;
end;

// ------------------------------ styles pass --------------------------------

procedure TCdrStylesPass.OnList(const ListType: AnsiString; Level: Integer; Start: Boolean);
var n: Integer;
begin
  if Start and (ListType = 'page') then
  begin
    n := Length(Doc.Pages);
    SetLength(Doc.Pages, n + 1);
    Doc.Pages[n].W := Doc.PageW;
    Doc.Pages[n].H := Doc.PageH;
  end;
end;

procedure TCdrStylesPass.OnChunk(const FourCC: AnsiString; const B: TBytes; Pos, Len, Level: Integer);
var
  R: TRd;
  w, h: Double;
  start, nargs, sargs, stypes, i: Integer;
  offs, types: TCardArr;
begin
  if not Doc.ChunkData(B, Pos, Len, R) then Exit;
  try
    if FourCC = 'vrsn' then Doc.SetVersion(R.U16)
    else if FourCC = 'fild' then Doc.ReadFild(R)
    else if FourCC = 'fill' then Doc.ReadFild(R)
    else if FourCC = 'outl' then Doc.ReadOutl(R)
    else if FourCC = 'bmp ' then Doc.ReadBmp(R, R.Left)
    else if FourCC = 'bmpf' then Doc.ReadBmpf(R, R.Left)
    else if FourCC = 'font' then Doc.ReadFont(R)
    else if FourCC = 'uidr' then Doc.ReadUidr(R)
    else if FourCC = 'stlt' then Doc.ReadStlt(R)
    else if FourCC = 'txsm' then Doc.ReadTxsm(R)
    else if FourCC = 'mcfg' then
    begin
      if Doc.Version >= 1300 then R.Skip(12)
      else if Doc.Version >= 900 then R.Skip(4)
      else if (Doc.Version < 700) and (Doc.Version >= 600) then R.Skip($1C);
      if Doc.Version < 400 then
      begin
        R.Skip(2);
        w := Doc.Coord(R); h := Doc.Coord(R);
        w := Abs(Doc.Coord(R) - w); h := Abs(Doc.Coord(R) - h);
      end
      else
      begin
        w := Doc.Coord(R); h := Doc.Coord(R);
      end;
      if (w > 0.01) and (h > 0.01) then
      begin
        Doc.PageW := w; Doc.PageH := h;
        if Length(Doc.Pages) > 0 then
        begin
          Doc.Pages[High(Doc.Pages)].W := w; Doc.Pages[High(Doc.Pages)].H := h;
        end;
      end;
    end
    else if (FourCC = 'loda') or (FourCC = 'lobj') then
    begin
      // page size arguments of the page's own layer records
      start := R.P;
      R.Skip(4);
      nargs := Doc.Uns(R); sargs := Doc.Uns(R); stypes := Doc.Uns(R);
      if (nargs <= 0) or (nargs > 4096) then Exit;
      SetLength(offs, nargs); SetLength(types, nargs);
      R.P := start + sargs;
      for i := 0 to nargs - 1 do offs[i] := Doc.Uns(R);
      R.P := start + stypes;
      for i := nargs - 1 downto 0 do types[i] := Doc.Uns(R);
      for i := 0 to nargs - 1 do
        if types[i] = $4ABA then
        begin
          R.P := start + Integer(offs[i]);
          w := Doc.Coord(R); h := Doc.Coord(R);
          if (w > 0.01) and (h > 0.01) and (Length(Doc.Pages) > 0) then
          begin
            Doc.Pages[High(Doc.Pages)].W := w; Doc.Pages[High(Doc.Pages)].H := h;
          end;
        end;
    end;
  except
    // a damaged record is skipped
  end;
end;

// ------------------------------ painter ------------------------------------

constructor TCdrPainter.Create(ADoc: TCdrDoc; AOut: TXVDocument);
begin
  inherited Create;
  Doc := ADoc;
  Out := AOut;
  FImgKeys := TStringList.Create;
  FImgKeys.Sorted := True;
  FBmpImg := TDictionary<Cardinal, Integer>.Create;
  PageIndex := -1;
  SX := PX_PER_INCH;
  ResetObject;
end;

destructor TCdrPainter.Destroy;
begin
  FImgKeys.Free;
  FBmpImg.Free;
  inherited Destroy;
end;

procedure TCdrPainter.AddItem(K: TOutKind; A, B, Clip: Integer);
var n: Integer;
begin
  n := Length(Items);
  SetLength(Items, n + 1);
  Items[n].Kind := K;
  Items[n].A := A;
  Items[n].B := B;
  Items[n].Clip := Clip;
end;

procedure TCdrPainter.ResetObject;
begin
  ObjActive := False;
  Path := nil;
  Fill := DefaultFill;
  Outl := DefaultOutl;
  StyleId := 0;
  Trafo := nil;
  Opacity := 1;
  HasBmp := False;
  TextKind := 0;
  IsPolygon := False; HasPolyTrafo := False; IsSpline := False;
  SplPts := nil; SplKnots := nil;
end;

// ---- path building (object coordinates, inches, y up) ----

procedure TCdrPainter.PMove(x, y: Double);
var n: Integer;
begin
  n := Length(Path); SetLength(Path, n + 1);
  Path[n].Cmd := 'M'; Path[n].X := x; Path[n].Y := y;
end;

procedure TCdrPainter.PLine(x, y: Double);
var n: Integer;
begin
  n := Length(Path); SetLength(Path, n + 1);
  Path[n].Cmd := 'L'; Path[n].X := x; Path[n].Y := y;
end;

procedure TCdrPainter.PCubic(x1, y1, x2, y2, x, y: Double);
var n: Integer;
begin
  n := Length(Path); SetLength(Path, n + 1);
  Path[n].Cmd := 'C';
  Path[n].X1 := x1; Path[n].Y1 := y1; Path[n].X2 := x2; Path[n].Y2 := y2;
  Path[n].X := x; Path[n].Y := y;
end;

procedure TCdrPainter.PQuad(x1, y1, x, y: Double);
var x0, y0: Double;
begin
  x0 := 0; y0 := 0;
  if Length(Path) > 0 then begin x0 := Path[High(Path)].X; y0 := Path[High(Path)].Y; end;
  PCubic(x0 + 2 / 3 * (x1 - x0), y0 + 2 / 3 * (y1 - y0), x + 2 / 3 * (x1 - x), y + 2 / 3 * (y1 - y), x, y);
end;

procedure TCdrPainter.PClose;
var n: Integer;
begin
  n := Length(Path); SetLength(Path, n + 1);
  Path[n].Cmd := 'Z';
  if n > 0 then begin Path[n].X := Path[n - 1].X; Path[n].Y := Path[n - 1].Y; end;
end;

// node types: $08 closes, $40/$80: 00 move, 40 line, 80 curve end, C0 control point
procedure TCdrPainter.ProcessPoints(const Pts: array of Double; const Types: TBytes);
var
  k, nt: Integer;
  t: Byte;
  closed: Boolean;
  tmp: array[0..3] of Double;
begin
  nt := 0;
  for k := 0 to High(Types) do
  begin
    if 2 * k + 1 > High(Pts) then Break;
    t := Types[k];
    closed := (t and $08) <> 0;
    if (t and $C0) = $00 then
    begin
      if closed then PClose;
      nt := 0;
      PMove(Pts[2 * k], Pts[2 * k + 1]);
    end
    else if (t and $C0) = $40 then
    begin
      nt := 0;
      PLine(Pts[2 * k], Pts[2 * k + 1]);
      if closed then PClose;
    end
    else if (t and $C0) = $80 then
    begin
      if nt >= 2 then PCubic(tmp[0], tmp[1], tmp[2], tmp[3], Pts[2 * k], Pts[2 * k + 1])
      else PLine(Pts[2 * k], Pts[2 * k + 1]);
      if closed then PClose;
      nt := 0;
    end
    else
    begin
      if nt < 2 then
      begin
        tmp[2 * nt] := Pts[2 * k]; tmp[2 * nt + 1] := Pts[2 * k + 1];
      end;
      Inc(nt);
    end;
  end;
end;

procedure TCdrPainter.ReadPoints(var R: TRd; Count: Integer);
var
  pts: array of Double;
  types: TBytes;
  i, ps: Integer;
begin
  if Doc.Prec32 then ps := 9 else ps := 5;
  if Count > R.Left div ps then Count := R.Left div ps;
  if Count <= 0 then Exit;
  SetLength(pts, 2 * Count);
  SetLength(types, Count);
  for i := 0 to Count - 1 do
  begin
    pts[2 * i] := Doc.Coord(R);
    pts[2 * i + 1] := Doc.Coord(R);
  end;
  for i := 0 to Count - 1 do types[i] := R.U8;
  ProcessPoints(pts, types);
end;

procedure TCdrPainter.ReadRectangle(var R: TRd);
var
  x0, y0, r0, r1, r2, r3, sx, sy, s, w, h, m: Double;
  corner, scaleWith: Integer;

  function RC: Double;
  begin
    if Doc.Version < 1500 then Result := Doc.Coord(R) else Result := R.F64 / 254000;
  end;

  procedure DoCorner(cx, cy, px, py, ex, ey: Double);
  begin
    // from the current point, around the corner (cx, cy) to (ex, ey)
    case corner of
      0: PQuad(cx, cy, ex, ey);
      1: PQuad(px, py, ex, ey);
    else
      PLine(ex, ey);
    end;
  end;

begin
  x0 := RC; y0 := RC;
  r0 := 0; r1 := 0; r2 := 0; r3 := 0;
  sx := 1; sy := 1;
  corner := 0;
  if Doc.Version < 1500 then
  begin
    r3 := RC;
    if Doc.Version < 900 then begin r2 := r3; r1 := r3; r0 := r3; end
    else begin r2 := RC; r1 := RC; r0 := RC; end;
  end
  else
  begin
    s := R.F64; if Abs(s) > 1e-9 then sx := s;
    s := R.F64; if Abs(s) > 1e-9 then sy := s;
    scaleWith := R.U8;
    R.Skip(7);
    if scaleWith = 0 then
    begin
      r3 := R.F64; corner := R.U8; R.Skip(15);
      r2 := R.F64; R.Skip(16);
      r1 := R.F64; R.Skip(16);
      r0 := R.F64;
      w := Abs(x0 * sx / 2); h := Abs(y0 * sy / 2);
      m := Min(w, h);
      r3 := r3 * m; r2 := r2 * m; r1 := r1 * m; r0 := r0 * m;
    end
    else
    begin
      r3 := RC; corner := R.U8; R.Skip(15);
      r2 := RC; R.Skip(16);
      r1 := RC; R.Skip(16);
      r0 := RC;
    end;
  end;
  if r0 > 0 then PMove(0, -r0 / sy) else PMove(0, 0);
  if r1 > 0 then
  begin
    PLine(0, y0 + r1 / sy);
    DoCorner(0, y0, r1 / sx, y0 + r1 / sy, r1 / sx, y0);
  end
  else PLine(0, y0);
  if r2 > 0 then
  begin
    PLine(x0 - r2 / sx, y0);
    DoCorner(x0, y0, x0 - r2 / sx, y0 + r2 / sy, x0, y0 + r2 / sy);
  end
  else PLine(x0, y0);
  if r3 > 0 then
  begin
    PLine(x0, -r3 / sy);
    DoCorner(x0, 0, x0 - r3 / sx, -r3 / sy, x0 - r3 / sx, 0);
  end
  else PLine(x0, 0);
  if r0 > 0 then
  begin
    PLine(r0 / sx, 0);
    DoCorner(0, 0, r0 / sx, -r0 / sy, 0, -r0 / sy);
  end
  else PLine(0, 0);
  PClose;
end;

procedure TCdrPainter.ReadEllipse(var R: TRd);
var
  x, y, a1, a2, cx, cy, rx, ry, d, k, t0, t1: Double;
  pie: Boolean;
  n, i: Integer;
  full: Boolean;
begin
  x := Doc.Coord(R); y := Doc.Coord(R);
  a1 := Doc.Ang(R); a2 := Doc.Ang(R);
  pie := Doc.Uns(R) <> 0;
  cx := x / 2; cy := y / 2; rx := Abs(cx); ry := Abs(cy);
  a1 := a1 - 2 * Pi * Floor(a1 / (2 * Pi));
  a2 := a2 - 2 * Pi * Floor(a2 / (2 * Pi));
  full := Abs(a1 - a2) < 1e-9;
  if full then a2 := a1 + 2 * Pi
  else if a2 < a1 then a2 := a2 + 2 * Pi;
  n := Max(1, Ceil((a2 - a1) / (Pi / 2) - 1e-9));
  d := (a2 - a1) / n;
  k := 4 / 3 * Tan(d / 4);
  PMove(cx + rx * Cos(a1), cy + ry * Sin(a1));
  for i := 0 to n - 1 do
  begin
    t0 := a1 + i * d; t1 := t0 + d;
    PCubic(cx + rx * Cos(t0) - k * rx * Sin(t0), cy + ry * Sin(t0) + k * ry * Cos(t0),
      cx + rx * Cos(t1) + k * rx * Sin(t1), cy + ry * Sin(t1) - k * ry * Cos(t1),
      cx + rx * Cos(t1), cy + ry * Sin(t1));
  end;
  if full then PClose
  else if pie then
  begin
    PLine(cx, cy);
    PClose;
  end;
end;

procedure TCdrPainter.ReadBitmapObj(var R: TRd);
var n: Integer;
begin
  if Doc.Version < 600 then
  begin
    BmpX1 := Doc.Coord(R); BmpY1 := Doc.Coord(R);
    BmpX2 := 0; BmpY2 := 0;
    if Doc.Version < 400 then R.Skip(2);
    R.Skip(8);
    BmpId := Doc.Uns(R);
  end
  else
  begin
    BmpX1 := Doc.Coord(R); BmpY1 := Doc.Coord(R);
    BmpX2 := Doc.Coord(R); BmpY2 := Doc.Coord(R);
    R.Skip(32);
    BmpId := Doc.Uns(R);
    if Doc.Version < 800 then R.Skip(8)
    else if Doc.Version < 900 then R.Skip(12)
    else R.Skip(20);
    n := R.U16;
    R.Skip(2);
    ReadPoints(R, n);
  end;
  HasBmp := True;
end;

procedure TCdrPainter.ReadLoda(var R: TRd);
var
  start, nargs, sargs, stypes, ctype, i, n: Integer;
  offs, types: TCardArr;
  id: Cardinal;
  F: TCdrFill;
  O: TCdrOutl;
begin
  start := R.P;
  R.Skip(4);
  nargs := Doc.Uns(R); sargs := Doc.Uns(R); stypes := Doc.Uns(R);
  ctype := Doc.Uns(R);
  if (nargs <= 0) or (nargs > 4096) then Exit;
  if ctype = $26 then IsSpline := True;
  SetLength(offs, nargs); SetLength(types, nargs);
  R.P := start + sargs;
  for i := 0 to nargs - 1 do offs[i] := Doc.Uns(R);
  R.P := start + stypes;
  for i := nargs - 1 downto 0 do types[i] := Doc.Uns(R);
  for i := 0 to nargs - 1 do
  begin
    R.P := start + Integer(offs[i]);
    case types[i] of
      $1E: begin
             if ((Doc.Version >= 400) and (ctype = 1)) or ((Doc.Version < 400) and (ctype = 0)) then ReadRectangle(R)
             else if ((Doc.Version >= 400) and (ctype = 2)) or ((Doc.Version < 400) and (ctype = 1)) then ReadEllipse(R)
             else if ((Doc.Version >= 400) and (ctype = 3)) or ((Doc.Version < 400) and (ctype = 2)) then
             begin
               n := R.U16; R.Skip(2);
               ReadPoints(R, n);
             end
             else if ctype = $25 then
             begin
               R.Skip(4);
               n := R.U16; n := n + R.U16;
               R.Skip(16);
               ReadPoints(R, n);
             end
             else if ((Doc.Version >= 400) and (ctype = 4)) or ((Doc.Version < 400) and (ctype = 3)) then
             begin
               TextKind := 1;
               TextX := Doc.Coord(R); TextY := Doc.Coord(R);
               // some versions leave no position here (the transform has it)
               if (Abs(TextX) > 500) or (Abs(TextY) > 500) then begin TextX := 0; TextY := 0; end;
               TextId := Spnd;
             end
             else if ((Doc.Version >= 400) and (ctype = 5)) or ((Doc.Version < 400) and (ctype = 4)) then
               ReadBitmapObj(R)
             else if ((Doc.Version >= 400) and (ctype = 6)) or ((Doc.Version < 400) and (ctype = 5)) then
             begin
               TextKind := 2;
               R.Skip(4);
               TextW := Doc.Coord(R); TextH := Doc.Coord(R);
               TextX := 0; TextY := 0;
               TextId := Spnd;
             end
             else if ctype = $14 then
             begin
               n := R.U16; R.Skip(2);
               ReadPoints(R, n);
               IsPolygon := True;
             end;
           end;
      $14: begin
             id := R.U32;
             if (id <> 0) and Doc.FindFill(id, F) then Fill := F;
           end;
      $0A: begin
             id := R.U32;
             if (id <> 0) and Doc.FindOutl(id, O) then Outl := O;
           end;
      $C8: begin
             id := Doc.Uns(R);
             if id <> 0 then StyleId := id;
           end;
      $2AF8: begin
               if Doc.Version < 1300 then R.Skip(4);
               PolyNum := R.U32;
               PolyNext := R.U32;
               if PolyNext <= 1 then PolyNext := R.U32 else R.Skip(4);
               if Doc.Version >= 1300 then R.Skip(4);
               PolyRx := R.F64; PolyRy := R.F64;
               PolyCx := Doc.Coord(R); PolyCy := Doc.Coord(R);
               HasPolyTrafo := True;
             end;
      $1F40: ReadOpacity(R);
    end;
  end;
end;

// Transparency. X3+ wraps it in a $514 block that holds the percentage as a
// double right after an $FFFFFFFF marker; older files keep a 1/1000 value.
procedure TCdrPainter.ReadOpacity(var R: TRd);
var
  st, len, q: Integer;
  v: Double;
  sub: TRd;
begin
  st := R.P;
  if (Doc.Version >= 1300) and (R.U32 = $514) then
  begin
    len := R.U32;
    q := R.P;
    while q + 12 <= Min(R.P + len, R.E) do
    begin
      if RdLE32(R.B, q) = $FFFFFFFF then
      begin
        sub.Init(R.B, q + 4, q + 12);
        v := sub.F64;
        if (v >= 0) and (v <= 100) and ((v > 0) or (RdLE32(R.B, q + 4) = 0)) then
        begin
          Opacity := EnsureRange(1 - v / 100, 0, 1);
          Exit;
        end;
      end;
      Inc(q);
    end;
    Exit;
  end;
  R.P := st;
  if Doc.Version < 1300 then R.Skip(10) else R.Skip(14);
  v := R.U16 / 1000;
  if (v > 0) and (v <= 1) then Opacity := v;
end;

procedure TCdrPainter.ReadTrfd(var R: TRd);
var
  start, nargs, sargs, i, t: Integer;
  offs: TCardArr;
  M: TMat;
begin
  start := R.P;
  R.Skip(4);
  nargs := Doc.Uns(R); sargs := Doc.Uns(R);
  if (nargs <= 0) or (nargs > 1024) then Exit;
  SetLength(offs, nargs);
  R.P := start + sargs;
  for i := 0 to nargs - 1 do offs[i] := Doc.Uns(R);
  Trafo := nil;
  for i := 0 to nargs - 1 do
  begin
    R.P := start + Integer(offs[i]);
    if Doc.Version >= 1300 then R.Skip(8);
    t := R.U16;
    if t = 8 then
    begin
      if Doc.Version >= 600 then R.Skip(6);
      if Doc.Version >= 500 then
      begin
        M.A := R.F64; M.B := R.F64; M.C := R.F64;
        M.D := R.F64; M.E := R.F64; M.F := R.F64;
        if Doc.Version < 600 then begin M.C := M.C / 1000; M.F := M.F / 1000; end
        else begin M.C := M.C / 254000; M.F := M.F / 254000; end;
      end
      else
      begin
        M.A := R.S32 / 65536; M.B := R.S32 / 65536; M.C := R.S32 / 1000;
        M.D := R.S32 / 65536; M.E := R.S32 / 65536; M.F := R.S32 / 1000;
      end;
      SetLength(Trafo, Length(Trafo) + 1);
      Trafo[High(Trafo)] := M;
    end;
  end;
end;

procedure TCdrPainter.ReadPpdt(var R: TRd);
var n, i, ps: Integer;
begin
  n := R.U16;
  if Doc.Prec32 then ps := 12 else ps := 8;
  if n > R.Left div ps then n := R.Left div ps;
  R.Skip(4);
  SetLength(SplPts, 2 * n);
  SetLength(SplKnots, n);
  for i := 0 to n - 1 do
  begin
    SplPts[2 * i] := Doc.Coord(R);
    SplPts[2 * i + 1] := Doc.Coord(R);
  end;
  for i := 0 to n - 1 do SplKnots[i] := R.U32;
end;

// a star / polygon: the stored path is one arm; copies are rotated around
procedure TCdrPainter.MakePolygon;
var
  src, res: TPath;
  step, ca, sa, ca1, sa1: Double;
  i, j, k, m: Integer;

  procedure Rot(var P: TPath; c, s: Double);
  var q: Integer; x, y: Double;
  begin
    for q := 0 to High(P) do
    begin
      x := P[q].X; y := P[q].Y;
      P[q].X := c * x + s * y; P[q].Y := -s * x + c * y;
      x := P[q].X1; y := P[q].Y1;
      P[q].X1 := c * x + s * y; P[q].Y1 := -s * x + c * y;
      x := P[q].X2; y := P[q].Y2;
      P[q].X2 := c * x + s * y; P[q].Y2 := -s * x + c * y;
    end;
  end;

  procedure Append(const P: TPath);
  var q, n0: Integer;
  begin
    n0 := Length(res);
    SetLength(res, n0 + Length(P));
    for q := 0 to High(P) do res[n0 + q] := P[q];
  end;

  procedure AppendClose;
  var n0: Integer;
  begin
    n0 := Length(res);
    SetLength(res, n0 + 1);
    res[n0].Cmd := 'Z';
  end;

begin
  if (PolyNum = 0) or (PolyNum > 1000) or (Length(Path) = 0) then Exit;
  src := Copy(Path);
  res := Copy(Path);
  step := 2 * Pi / PolyNum;
  ca := Cos(PolyNext * step); sa := Sin(PolyNext * step);
  if (PolyNext <> 0) and ((PolyNum mod PolyNext) <> 0) then
  begin
    for i := 1 to PolyNum - 1 do
    begin
      Rot(src, ca, sa);
      Append(src);
    end;
  end
  else
  begin
    ca1 := Cos(step); sa1 := Sin(step);
    if PolyNext = 0 then m := 1 else m := PolyNum div PolyNext;
    for i := 0 to Integer(PolyNext) - 1 do
    begin
      if i > 0 then
      begin
        Rot(src, ca1, sa1);
        Append(src);
      end;
      for j := 1 to m - 1 do
      begin
        Rot(src, ca, sa);
        Append(src);
      end;
      AppendClose;
    end;
  end;
  AppendClose;
  for k := 0 to High(res) do
  begin
    res[k].X := PolyRx * res[k].X + PolyCx; res[k].Y := PolyRy * res[k].Y + PolyCy;
    res[k].X1 := PolyRx * res[k].X1 + PolyCx; res[k].Y1 := PolyRy * res[k].Y1 + PolyCy;
    res[k].X2 := PolyRx * res[k].X2 + PolyCx; res[k].Y2 := PolyRy * res[k].Y2 + PolyCy;
  end;
  Path := res;
end;

// clamped uniform cubic B-spline (libcdr's knot vector), sampled by de Boor
procedure TCdrPainter.MakeSpline;
var
  n, i, j: Integer;
  seg: array of Double;

  procedure SplineTo(const P: array of Double; Cnt: Integer);
  var
    span, steps, s, r, k: Integer;
    t, tmax, alpha: Double;
    d: array[0..3, 0..1] of Double;

    function Knot(idx: Integer): Double;
    begin
      if idx < 3 then Result := 0
      else if idx > Cnt then Result := Cnt - 3
      else Result := idx - 3;
    end;

  begin
    tmax := Cnt - 3;
    steps := Max(8, (Cnt - 3) * 12);
    for s := 1 to steps do
    begin
      t := tmax * s / steps;
      span := 3;
      while (span < Cnt - 1) and (Knot(span + 1) <= t) do Inc(span);
      for k := 0 to 3 do
      begin
        d[k, 0] := P[2 * (span - 3 + k)];
        d[k, 1] := P[2 * (span - 3 + k) + 1];
      end;
      for r := 1 to 3 do
        for k := 3 downto r do
        begin
          if Knot(k + 1 + span - r) - Knot(k + span - 3) > 1e-12 then
            alpha := (t - Knot(k + span - 3)) / (Knot(k + 1 + span - r) - Knot(k + span - 3))
          else alpha := 0;
          d[k, 0] := (1 - alpha) * d[k - 1, 0] + alpha * d[k, 0];
          d[k, 1] := (1 - alpha) * d[k - 1, 1] + alpha * d[k, 1];
        end;
      PLine(d[3, 0], d[3, 1]);
    end;
  end;

  procedure Piece;
  var c: Integer;
  begin
    c := Length(seg) div 2;
    if c = 2 then PLine(seg[2], seg[3])
    else if c = 3 then PQuad(seg[2], seg[3], seg[4], seg[5])
    else if c > 3 then SplineTo(seg, c);
  end;

begin
  n := Min(Length(SplPts) div 2, Length(SplKnots));
  if n = 0 then Exit;
  Path := nil;
  PMove(SplPts[0], SplPts[1]);
  SetLength(seg, 2);
  seg[0] := SplPts[0]; seg[1] := SplPts[1];
  for i := 1 to n - 1 do
  begin
    j := Length(seg);
    SetLength(seg, j + 2);
    seg[j] := SplPts[2 * i]; seg[j + 1] := SplPts[2 * i + 1];
    if SplKnots[i] <> 0 then
    begin
      Piece;
      SetLength(seg, 2);
      seg[0] := SplPts[2 * i]; seg[1] := SplPts[2 * i + 1];
    end;
  end;
  if Length(seg) > 2 then Piece;
end;

procedure TCdrPainter.Apply(var x, y: Double);
var i: Integer; tx: Double;
begin
  for i := 0 to High(Trafo) do
  begin
    tx := Trafo[i].A * x + Trafo[i].B * y + Trafo[i].C;
    y := Trafo[i].D * x + Trafo[i].E * y + Trafo[i].F;
    x := tx;
  end;
end;

function TCdrPainter.Det: Double;
var x0, y0, x1, y1, x2, y2: Double;
begin
  x0 := 0; y0 := 0; Apply(x0, y0);
  x1 := 1; y1 := 0; Apply(x1, y1);
  x2 := 0; y2 := 1; Apply(x2, y2);
  Result := (x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0);
end;

// object coordinates -> output pixels
procedure TCdrPainter.MapPt(x, y: Double; out ox, oy: Double);
begin
  Apply(x, y);
  ox := (x + PageW / 2) * SX;
  oy := (PageH / 2 - y) * SX;
end;

// the object's path in output pixels; sub-paths that end where they
// started are closed
function TCdrPainter.BuildPath(out Empty: Boolean; out MinX, MinY, MaxX, MaxY: Double): TXVPath;
var
  i: Integer;
  x, y, x1, y1, x2, y2, sx0, sy0, px, py: Double;
  open, any, lastZ: Boolean;

  procedure Track(a, b: Double);
  begin
    if a < MinX then MinX := a;
    if a > MaxX then MaxX := a;
    if b < MinY then MinY := b;
    if b > MaxY then MaxY := b;
  end;

  procedure CloseIfBack;
  begin
    if open and not lastZ and (Abs(px - sx0) < 1e-3) and (Abs(py - sy0) < 1e-3) then
    begin
      Result.Close;
      lastZ := True;
    end;
  end;

begin
  MinX := 1e300; MinY := 1e300; MaxX := -1e300; MaxY := -1e300;
  Result := Default(TXVPath);
  Result.Clear;
  open := False; any := False; lastZ := False;
  sx0 := 0; sy0 := 0; px := 0; py := 0;
  for i := 0 to High(Path) do
    case Path[i].Cmd of
      'M': begin
             MapPt(Path[i].X, Path[i].Y, x, y);
             if open and (Abs(x - px) < 1e-3) and (Abs(y - py) < 1e-3) then Continue;
             CloseIfBack;
             Result.MoveTo(x, y);
             open := True; lastZ := False;
             sx0 := x; sy0 := y; px := x; py := y;
             Track(x, y);
           end;
      'L': begin
             MapPt(Path[i].X, Path[i].Y, x, y);
             if not open then
             begin
               Result.MoveTo(px, py);
               open := True; sx0 := px; sy0 := py;
             end;
             Result.LineTo(x, y);
             px := x; py := y; any := True; lastZ := False;
             Track(x, y);
           end;
      'C': begin
             MapPt(Path[i].X1, Path[i].Y1, x1, y1);
             MapPt(Path[i].X2, Path[i].Y2, x2, y2);
             MapPt(Path[i].X, Path[i].Y, x, y);
             if not open then
             begin
               Result.MoveTo(px, py);
               open := True; sx0 := px; sy0 := py;
             end;
             Result.CubicTo(x1, y1, x2, y2, x, y);
             px := x; py := y; any := True; lastZ := False;
             Track(x1, y1); Track(x2, y2); Track(x, y);
           end;
      'Z': if open and not lastZ and any then
           begin
             Result.Close;
             lastZ := True;
             px := sx0; py := sy0;
           end;
    end;
  CloseIfBack;
  Empty := not any;
end;

// ---- fills ----

function TCdrPainter.ColorAt(const F: TCdrFill; t: Double): Cardinal;
var
  i: Integer;
  a, b: Cardinal;
  u, o0, o1: Double;
begin
  if Length(F.Stops) = 0 then Exit(Doc.Rgb(F.Color1));
  t := EnsureRange(t, 0, 1);
  if t <= F.Stops[0].Offset then Exit(Doc.Rgb(F.Stops[0].Color));
  for i := 0 to High(F.Stops) - 1 do
  begin
    o0 := F.Stops[i].Offset; o1 := F.Stops[i + 1].Offset;
    if t <= o1 then
    begin
      a := Doc.Rgb(F.Stops[i].Color); b := Doc.Rgb(F.Stops[i + 1].Color);
      if o1 - o0 > 1e-9 then u := (t - o0) / (o1 - o0) else u := 1;
      Exit((Cardinal(ClampB(((a shr 16) and $FF) * (1 - u) + ((b shr 16) and $FF) * u)) shl 16) or
        (Cardinal(ClampB(((a shr 8) and $FF) * (1 - u) + ((b shr 8) and $FF) * u)) shl 8) or
        Cardinal(ClampB((a and $FF) * (1 - u) + (b and $FF) * u)));
    end;
  end;
  Result := Doc.Rgb(F.Stops[High(F.Stops)].Color);
end;

// Fountain fill as a gradient over the object's box. The edge pad of
// CorelDRAW squeezes the colours towards the middle of the range; linear
// (and conical) fills run against the angle, radial and square ones start
// with the first colour outside.
function TCdrPainter.FountainPaint(const F: TCdrFill; MinX, MinY, MaxX, MaxY: Double): TXVPaint;
var
  g: TXVGradient;
  e, w, h, dx, dy, t, tmin, tmax, tc, cx, cy, rad: Double;
  i, n: Integer;
  corners: array[0..3, 0..1] of Double;
  r, gg, b: Integer;
  c: Cardinal;
begin
  n := Length(F.Stops);
  g := Default(TXVGradient);
  g.Matrix := TXVMatrix.Identity;
  g.Spread := spPad;
  e := EnsureRange(F.GEdge / 100, 0, 0.9);
  w := MaxX - MinX; h := MaxY - MinY;
  corners[0, 0] := MinX; corners[0, 1] := MinY; corners[1, 0] := MaxX; corners[1, 1] := MinY;
  corners[2, 0] := MinX; corners[2, 1] := MaxY; corners[3, 0] := MaxX; corners[3, 1] := MaxY;
  SetLength(g.Stops, n);
  r := 0; gg := 0; b := 0;
  if F.GType in [2, 4] then
  begin
    g.Kind := gkRadial;
    cx := MinX + w * (0.5 + F.GCx / 200);
    cy := MinY + h * (0.5 - F.GCy / 200);
    rad := 0;
    for i := 0 to 3 do rad := Max(rad, Hypot(corners[i, 0] - cx, corners[i, 1] - cy));
    if rad <= 0 then rad := 1;
    g.CX := cx; g.CY := cy; g.R := rad; g.FX := cx; g.FY := cy;
    // offset 0 = centre: the first stop sits outside
    for i := 0 to n - 1 do
    begin
      c := Doc.Rgb(F.Stops[i].Color);
      g.Stops[n - 1 - i].Offset := EnsureRange(1 - (e / 2 + F.Stops[i].Offset * (1 - e)), 0, 1);
      g.Stops[n - 1 - i].Color := $FF000000 or c;
    end;
  end
  else
  begin
    g.Kind := gkLinear;
    dx := Cos(F.GAngle); dy := -Sin(F.GAngle);
    tmin := 1e300; tmax := -1e300;
    for i := 0 to 3 do
    begin
      t := corners[i, 0] * dx + corners[i, 1] * dy;
      tmin := Min(tmin, t); tmax := Max(tmax, t);
    end;
    cx := (MinX + MaxX) / 2; cy := (MinY + MaxY) / 2;
    tc := cx * dx + cy * dy;
    g.X1 := cx + dx * (tmin - tc); g.Y1 := cy + dy * (tmin - tc);
    g.X2 := cx + dx * (tmax - tc); g.Y2 := cy + dy * (tmax - tc);
    for i := 0 to n - 1 do
    begin
      c := Doc.Rgb(F.Stops[i].Color);
      g.Stops[i].Offset := EnsureRange(e / 2 + F.Stops[i].Offset * (1 - e), 0, 1);
      g.Stops[i].Color := $FF000000 or c;
    end;
  end;
  for i := 1 to n - 1 do
    if g.Stops[i].Offset < g.Stops[i - 1].Offset then g.Stops[i].Offset := g.Stops[i - 1].Offset;
  for i := 0 to n - 1 do
  begin
    Inc(r, XVColorR(g.Stops[i].Color)); Inc(gg, XVColorG(g.Stops[i].Color)); Inc(b, XVColorB(g.Stops[i].Color));
  end;
  Result := XVGradientPaint(Out.AddGradient(g), XVRGB(r div n, gg div n, b div n));
end;

// two-colour (bitmap pattern) and bitmap / texture fills as image patterns
function TCdrPainter.PatternPaint(const F: TCdrFill; MinX, MinY, MaxX, MaxY: Double): TXVPaint;
var
  key: string;
  tw, th, sc: Double;
  i, x, y, k, ii: Integer;
  fg, bg: Cardinal;
  P: TCdrPattern;
  img: TXVImage;
  bit: Boolean;
begin
  Result := XVNoPaint;
  // tile size in output pixels
  if F.ImgRel then
  begin
    tw := (MaxX - MinX) * F.ImgW / 100; th := (MaxY - MinY) * F.ImgH / 100;
  end
  else
  begin
    sc := 1;
    if (F.ImgFlags and 4) <> 0 then sc := Sqrt(Abs(Det));
    tw := F.ImgW * SX * sc; th := F.ImgH * SX * sc;
  end;
  if (tw < 0.5) or (th < 0.5) then Exit;
  fg := Doc.Rgb(F.Color1); bg := Doc.Rgb(F.Color2);
  key := IntToStr(F.Kind) + '_' + IntToStr(F.ImgId) + '_' + IntToHex(fg, 6) + IntToHex(bg, 6);
  if FImgKeys.Find(key, i) then ii := Integer(PtrInt(FImgKeys.Objects[i]))
  else
  begin
    if F.Kind in [7, 8] then
    begin
      if not Doc.PatternIdx.TryGetValue(F.ImgId, k) then Exit;
      P := Doc.Patterns[k];
      img := XVNewImage(P.W, P.H);
      for y := 0 to P.H - 1 do
        for x := 0 to P.W - 1 do
        begin
          k := y * ((P.W + 7) div 8) + x div 8;
          bit := (k < Length(P.Bits)) and ((P.Bits[k] and ($80 shr (x and 7))) <> 0);
          if bit then img.Px[y * P.W + x] := $FF000000 or bg else img.Px[y * P.W + x] := $FF000000 or fg;
        end;
    end
    else
    begin
      if not Doc.ImageIdx.TryGetValue(F.ImgId, k) then Exit;
      img.W := Doc.Images[k].W; img.H := Doc.Images[k].H;
      img.Px := Doc.Images[k].Px;
      if (img.W <= 0) or (img.H <= 0) then Exit;
    end;
    ii := Out.AddImageData(img);
    FImgKeys.AddObject(key, TObject(PtrInt(ii)));
  end;
  img := Out.Images[ii];
  Result := XVPatternPaint(Out.AddPattern(ii, TXVMatrix.Make(tw / img.W, 0, 0, th / img.H, MinX, MaxY)),
    XVImageAverage(img));
end;

function TCdrPainter.MakeStroke: TXVStroke;
var
  O: TCdrOutl;
  w, sc, sx0, sy0, x0, y0, x1, y1: Double;
  i: Integer;
begin
  O := Outl;
  if (O.LineType = -1) and (StyleId <> 0) then O := Doc.GetStyle(StyleId).Outl;
  if (O.LineType = -1) or ((O.LineType and 1) <> 0) then Exit(XVNoStroke);
  if (O.LineType and 6) = 0 then Exit(XVStroke(XV_BLACK, 0.5));
  sc := 1;
  if (O.LineType and $20) <> 0 then
  begin
    x0 := 0; y0 := 0; Apply(x0, y0);
    x1 := 1; y1 := 0; Apply(x1, y1); sx0 := Abs(x1 - x0);
    x1 := 0; y1 := 1; Apply(x1, y1); sy0 := Abs(y1 - y0);
    sc := Max(sx0, sy0);
  end;
  if O.Stretch > 0 then sc := sc * O.Stretch;
  w := O.Width * sc * SX;
  if w < 0.35 then w := 0.35;
  Result := XVStroke($FF000000 or Doc.Rgb(O.Color), w);
  case O.Caps of
    1: Result.Cap := lcRound;
    2: Result.Cap := lcSquare;
  else
    Result.Cap := lcButt;
  end;
  case O.Join of
    1: Result.Join := ljRound;
    2: Result.Join := ljBevel;
  else
    Result.Join := ljMiter;
  end;
  if ((O.LineType and 4) <> 0) and (Length(O.Dash) >= 2) then
  begin
    SetLength(Result.Dashes, Length(O.Dash));
    for i := 0 to High(O.Dash) do Result.Dashes[i] := Max(O.Dash[i], 0.1) * w;
  end;
end;

// bitmap objects: the image under the object transform, cropped to the
// object's path
procedure TCdrPainter.EmitBitmap(const P: TXVPath; PEmpty: Boolean);
var
  k, ii: Integer;
  left, right, top, bottom, ax, ay, bx, by, cx, cy: Double;
  m: TXVMatrix;
  img: TXVImage;
begin
  if not Doc.ImageIdx.TryGetValue(BmpId, k) then Exit;
  if (Doc.Images[k].W <= 0) or (Doc.Images[k].H <= 0) then Exit;
  left := Min(BmpX1, BmpX2); right := Max(BmpX1, BmpX2);
  bottom := Min(BmpY1, BmpY2); top := Max(BmpY1, BmpY2);
  if (right - left < 1e-9) or (top - bottom < 1e-9) then Exit;
  if not FBmpImg.TryGetValue(BmpId, ii) then
  begin
    img.W := Doc.Images[k].W; img.H := Doc.Images[k].H;
    img.Px := Doc.Images[k].Px;
    ii := Out.AddImageData(img);
    FBmpImg.Add(BmpId, ii);
  end;
  MapPt(left, top, ax, ay); MapPt(right, top, bx, by); MapPt(left, bottom, cx, cy);
  m := TXVMatrix.Make((bx - ax) / Doc.Images[k].W, (by - ay) / Doc.Images[k].W,
    (cx - ax) / Doc.Images[k].H, (cy - ay) / Doc.Images[k].H, ax, ay);
  if not PEmpty and (P.NCmd > 0) then
  begin
    Out.BeginGroup(Out.AddClip(P, frNonZero), 1);
    Out.AddImage(ii, m, Opacity);
    Out.EndGroup;
  end
  else Out.AddImage(ii, m, Opacity);
end;

// artistic and paragraph text
procedure TCdrPainter.EmitText;
type
  TLineRun = record
    Text: string;
    Style: TCdrStyle;
  end;
  TLine = array of TLineRun;
var
  k, pIdx, ri, li, i, nn, ln, cut, first, idx: Integer;
  wpart: UnicodeString;
  lines: array of TLine;
  cur: TLine;
  s, part: string;
  ks, ang, lineH, maxSz, y, x, ox, oy, sz, width, cw: Double;
  x0, y0, x1, y1: Double;
  run: TLineRun;
  font: TXVFont;
  m: TXVMatrix;
  anchor: TXVTextAnchor;

  procedure PushLine;
  var q: Integer;
  begin
    q := Length(lines);
    SetLength(lines, q + 1);
    lines[q] := cur;
    cur := nil;
  end;

  procedure AddToLine(const T: string; const S: TCdrStyle);
  var q: Integer;
  begin
    q := Length(cur);
    SetLength(cur, q + 1);
    cur[q].Text := T;
    cur[q].Style := S;
  end;

  function StyleSize(const S: TCdrStyle): Double;
  begin
    if S.Size > 1e-6 then Result := S.Size else Result := 12 / 72;
  end;

  function RunColor(const S: TCdrStyle): Cardinal;
  begin
    if S.Fill.Kind = 1 then Result := Doc.Rgb(S.Fill.Color1)
    else if (S.Fill.Kind = 2) and (Length(S.Fill.Stops) > 0) then Result := Doc.Rgb(S.Fill.Stops[0].Color)
    else Result := 0;
  end;

begin
  if not Doc.TextIdx.TryGetValue(TextId, k) then Exit;
  // split the paragraphs into lines at CR / LF
  lines := nil; cur := nil;
  for pIdx := 0 to High(Doc.Texts[k].Paras) do
  begin
    for ri := 0 to High(Doc.Texts[k].Paras[pIdx]) do
    begin
      s := Doc.Texts[k].Paras[pIdx][ri].Text;
      while s <> '' do
      begin
        i := Pos(#13, s); nn := Pos(#10, s);
        if (nn > 0) and ((i = 0) or (nn < i)) then i := nn;
        if i = 0 then begin AddToLine(s, Doc.Texts[k].Paras[pIdx][ri].Style); Break; end;
        part := Copy(s, 1, i - 1);
        if part <> '' then AddToLine(part, Doc.Texts[k].Paras[pIdx][ri].Style);
        PushLine;
        // keep the style of an empty line for its height
        if Length(lines[High(lines)]) = 0 then
        begin
          SetLength(lines[High(lines)], 1);
          lines[High(lines)][0].Text := '';
          lines[High(lines)][0].Style := Doc.Texts[k].Paras[pIdx][ri].Style;
        end;
        if (i < Length(s)) and (s[i] = #13) and (s[i + 1] = #10) then Inc(i);
        Delete(s, 1, i);
      end;
    end;
    if Length(cur) > 0 then PushLine;
  end;
  if Length(lines) = 0 then Exit;
  // paragraph frames: wrap long lines by an estimated character width
  if (TextKind = 2) and (TextW > 0) then
  begin
    i := 0;
    while i <= High(lines) do
    begin
      width := 0;
      for ri := 0 to High(lines[i]) do
      begin
        cw := 0.52 * StyleSize(lines[i][ri].Style);
        width := width + Length(UTF8Decode(lines[i][ri].Text)) * cw;
      end;
      if (width > TextW) and (Length(lines[i]) = 1) then
      begin
        s := lines[i][0].Text;
        cw := 0.52 * StyleSize(lines[i][0].Style);
        nn := Max(1, Trunc(TextW / cw));
        wpart := UTF8Decode(s);
        cut := Min(nn, Length(wpart));
        while (cut > 1) and (wpart[cut] <> ' ') do Dec(cut);
        if cut <= 1 then cut := Min(nn, Length(wpart));
        run := lines[i][0];
        lines[i][0].Text := UTF8Encode(TrimRight(Copy(wpart, 1, cut)));
        SetLength(lines, Length(lines) + 1);
        for ln := High(lines) downto i + 2 do lines[ln] := lines[ln - 1];
        SetLength(lines[i + 1], 1);
        lines[i + 1][0] := run;
        lines[i + 1][0].Text := UTF8Encode(TrimLeft(Copy(wpart, cut + 1, MaxInt)));
      end;
      Inc(i);
    end;
  end;
  // direction and scale of the text from the transform
  x0 := 0; y0 := 0; Apply(x0, y0);
  x1 := 1; y1 := 0; Apply(x1, y1);
  ang := ArcTan2(y1 - y0, x1 - x0);
  ks := Sqrt(Abs(Det));
  if ks <= 1e-9 then ks := 1;
  y := TextY;
  for li := 0 to High(lines) do
  begin
    maxSz := 0;
    for ri := 0 to High(lines[li]) do maxSz := Max(maxSz, StyleSize(lines[li][ri].Style));
    lineH := maxSz * 1.2;
    anchor := taStart;
    case lines[li][0].Style.Align of
      2: anchor := taMiddle;
      3: anchor := taEnd;
    end;
    if TextKind = 2 then
    begin
      if li = 0 then y := TextY - maxSz else y := y - lineH;
      case anchor of
        taMiddle: x := TextX + TextW / 2;
        taEnd: x := TextX + TextW;
      else
        x := TextX;
      end;
    end
    else
    begin
      if li > 0 then y := y - lineH;
      x := TextX;
    end;
    // the first run is placed, the others continue after it; the anchor of
    // the line applies to all of them
    first := -1;
    for ri := 0 to High(lines[li]) do
    begin
      run := lines[li][ri];
      if run.Text = '' then Continue;
      sz := StyleSize(run.Style) * SX * ks;
      font := XVDefaultFont;
      font.Family := run.Style.Font;
      if font.Family = '' then font.Family := 'Arial';
      font.Size := EnsureRange(sz, 0.5, 1e5);
      MapPt(x, y, ox, oy);
      // the object y axis points up: the baseline angle turns the other way
      m := XVMul(TXVMatrix.Translate(ox, oy), TXVMatrix.Rotate(-ang));
      if first >= 0 then
      begin
        m.E := 0; m.F := 0;
      end;
      idx := Out.AddText(run.Text, font, m, XVSolid($FF000000 or RunColor(run.Style)), anchor);
      Out.Elements[idx].Opacity := Opacity;
      Out.Elements[idx].Continued := first >= 0;
      if first < 0 then first := idx;
    end;
  end;
end;

procedure TCdrPainter.EmitObject;
var
  P: TXVPath;
  empty: Boolean;
  mnx, mny, mxx, mxy: Double;
  F: TCdrFill;
  fp: TXVPaint;
  st: TXVStroke;
  rule: TXVFillRule;
begin
  if IsPolygon and HasPolyTrafo then MakePolygon;
  if IsSpline and (Length(SplPts) > 0) then MakeSpline;
  P := BuildPath(empty, mnx, mny, mxx, mxy);
  if HasBmp then
  begin
    EmitBitmap(P, empty);
    Exit;
  end;
  if (P.NCmd > 0) and not empty then
  begin
    F := Fill;
    if (F.Kind = -1) and (StyleId <> 0) then F := Doc.GetStyle(StyleId).Fill;
    fp := XVNoPaint;
    case F.Kind of
      1: fp := XVSolid($FF000000 or Doc.Rgb(F.Color1));
      2: if Length(F.Stops) = 1 then fp := XVSolid($FF000000 or Doc.Rgb(F.Stops[0].Color))
         else if Length(F.Stops) >= 2 then fp := FountainPaint(F, mnx, mny, mxx, mxy);
      7, 8, 9, 11:
         begin
           fp := PatternPaint(F, mnx, mny, mxx, mxy);
           if (fp.Kind = pkNone) and (F.Kind in [7, 8]) then fp := XVSolid($FF000000 or Doc.Rgb(F.Color2));
         end;
    end;
    st := MakeStroke;
    if (fp.Kind <> pkNone) or (st.Paint.Kind <> pkNone) then
    begin
      if IsPolygon then rule := frNonZero else rule := frEvenOdd;
      Out.AddPath(P, fp, st, rule, Opacity);
    end;
  end;
  if TextKind <> 0 then EmitText;
end;

procedure TCdrPainter.Flush;
var a: Integer;
begin
  if not ObjActive then Exit;
  if DrawPage and not IgnorePage and (VectLevel = 0) then
  begin
    a := Out.Count;
    try
      EmitObject;
    except
      Out.Truncate(a);
    end;
    if Out.Count > a then AddItem(okElem, a, Out.Count, -1);
  end;
  ResetObject;
end;

procedure TCdrPainter.OnList(const ListType: AnsiString; Level: Integer; Start: Boolean);
var
  n, a, clip: Integer;
  P: TXVPath;
  empty: Boolean;
  q1, q2, q3, q4: Double;
begin
  if Start then
  begin
    if ListType = 'page' then
    begin
      Flush;
      Inc(PageIndex);
      PageProps := True;
      IgnorePage := False;
      PageLevel := Level;
      PageObjs := 0;
      DrawPage := not PageDone;
      PageItemStart := Length(Items);
      PageElemStart := Out.Count;
      if DrawPage and (PageIndex < Length(Doc.Pages)) then
      begin
        PageW := Doc.Pages[PageIndex].W; PageH := Doc.Pages[PageIndex].H;
      end;
    end
    else if ListType = 'obj ' then
    begin
      Flush;
      ObjActive := True;
      ObjLevel := Level;
      Inc(PageObjs);
    end
    else if ListType = 'vect' then
    begin
      Flush;
      if VectLevel = 0 then VectLevel := Level;
    end
    else if ListType = 'clpt' then
    begin
      // PowerClip: the contents are drawn clipped to the container (the
      // object that holds this list); the container itself goes below them
      clip := -1;
      a := Out.Count;
      if ObjActive and DrawPage and not IgnorePage and (VectLevel = 0) then
      begin
        P := BuildPath(empty, q1, q2, q3, q4);
        if (P.NCmd > 0) and not empty then clip := Out.AddClip(P, frNonZero);
        try
          EmitObject;
        except
          Out.Truncate(a);
        end;
      end;
      ResetObject;
      n := Length(Clips);
      SetLength(Clips, n + 1);
      Clips[n].Level := Level;
      Clips[n].Clip := clip;
      Clips[n].ContA := a;
      Clips[n].ContB := Out.Count;
      if clip >= 0 then AddItem(okOpen, 0, 0, clip);
    end;
  end
  else
  begin
    if ObjActive and (Level <= ObjLevel) then Flush;
    if (ListType = 'clpt') and (Length(Clips) > 0) and (Clips[High(Clips)].Level = Level) then
    begin
      Flush;
      if Clips[High(Clips)].Clip >= 0 then AddItem(okClose, 0, 0, Clips[High(Clips)].Clip);
      if Clips[High(Clips)].ContB > Clips[High(Clips)].ContA then
        AddItem(okElem, Clips[High(Clips)].ContA, Clips[High(Clips)].ContB, -1);
      SetLength(Clips, Length(Clips) - 1);
    end;
    if (VectLevel > 0) and (Level <= VectLevel) then VectLevel := 0;
    if (ListType = 'page') and (Level <= PageLevel) then
    begin
      Flush;
      if not IgnorePage and (PageObjs > 0) then
      begin
        // a page that is drawn: the chosen one is kept
        if DrawPage and (DrawnPages = TargetPage) then PageDone := True
        else if DrawPage then
        begin
          SetLength(Items, PageItemStart);
          Out.Truncate(PageElemStart);
        end;
        Inc(DrawnPages);
      end
      else if DrawPage then
      begin
        SetLength(Items, PageItemStart);
        Out.Truncate(PageElemStart);
      end;
      DrawPage := False;
    end;
  end;
end;

procedure TCdrPainter.OnChunk(const FourCC: AnsiString; const B: TBytes; Pos, Len, Level: Integer);
var
  R: TRd;
  fl: Cardinal;
begin
  if not Doc.ChunkData(B, Pos, Len, R) then Exit;
  try
    if FourCC = 'vrsn' then Doc.SetVersion(R.U16)
    else if FourCC = 'flgs' then
    begin
      fl := R.U32;
      if PageProps then
      begin
        if ((fl and $00FF0000) <> 0) and (Doc.Version >= 400) then IgnorePage := True;
        PageProps := False;
      end;
    end
    else if FourCC = 'spnd' then Spnd := Doc.Uns(R)
    else if not ObjActive then Exit
    else if (FourCC = 'loda') or (FourCC = 'lobj') then ReadLoda(R)
    else if FourCC = 'trfd' then ReadTrfd(R)
    else if FourCC = 'ppdt' then ReadPpdt(R);
  except
    // a damaged record is skipped
  end;
end;

// Items are in file order (top-most object first): they go into the
// document in reverse, with the ends of the clip groups swapped.
procedure TCdrPainter.Finish;
var
  els: array of TXVElement;
  n, i, k: Integer;

  procedure Add(const E: TXVElement);
  begin
    if n >= Length(els) then SetLength(els, Max(64, n * 2));
    els[n] := E;
    Inc(n);
  end;

var g: TXVElement;
begin
  n := 0;
  els := nil;
  for i := High(Items) downto 0 do
    case Items[i].Kind of
      okElem:
        for k := Items[i].A to Items[i].B - 1 do
          if k < Out.Count then Add(Out.Elements[k]);
      okClose:
        begin
          g := Default(TXVElement);
          g.Kind := ekGroup;
          g.Clip := Items[i].Clip;
          g.Opacity := 1;
          g.Image := -1;
          g.Matrix := TXVMatrix.Identity;
          Add(g);
        end;
      okOpen:
        begin
          g := Default(TXVElement);
          g.Kind := ekGroupEnd;
          g.Opacity := 1;
          g.Clip := -1;
          g.Image := -1;
          g.Matrix := TXVMatrix.Identity;
          Add(g);
        end;
    end;
  SetLength(els, n);
  Out.SetElements(els);
end;

// ------------------------------ entry points -------------------------------

function XVIsCDR(const Data: TBytes): Boolean;
var L: TZipEntries;
begin
  Result := False;
  if Length(Data) < 12 then Exit;
  if (Data[0] = Ord('R')) and (Data[1] = Ord('I')) and (Data[2] = Ord('F')) and (Data[3] = Ord('F')) then
    Exit(((Data[8] = Ord('C')) or (Data[8] = Ord('c'))) and ((Data[9] = Ord('D')) or (Data[9] = Ord('d'))) and
      ((Data[10] = Ord('R')) or (Data[10] = Ord('r'))));
  if (Data[0] = Ord('P')) and (Data[1] = Ord('K')) then
  begin
    L := ZipList(Data);
    Result := (ZipFind(L, 'content/root.dat') >= 0) or (ZipFind(L, 'content/riffData.cdr') >= 0);
  end;
end;

procedure XVReadCDRDoc(Doc: TXVDocument; const Data: TBytes);
var
  CD: TCdrDoc;
  SP: TCdrStylesPass;
  PP: TCdrPainter;
  L: TZipEntries;
  i, k, n: Integer;
  list: TBytes;
  names: TStringList;
  s: string;
  pw, ph: Double;
begin
  if not XVIsCDR(Data) then raise EXVError.Create('CDR: not a CorelDRAW file');
  CD := TCdrDoc.Create;
  try
    if Data[0] = Ord('P') then
    begin
      L := ZipList(Data);
      i := ZipFind(L, 'content/root.dat');
      if i >= 0 then
      begin
        CD.Root := ZipRead(Data, L[i]);
        k := ZipFind(L, 'content/dataFileList.dat');
        if k >= 0 then
        begin
          list := ZipRead(Data, L[k]);
          names := TStringList.Create;
          try
            SetLength(s, Length(list));
            if Length(list) > 0 then Move(list[0], s[1], Length(list));
            names.Text := s;
            SetLength(CD.Streams, names.Count);
            n := 0;
            for k := 0 to names.Count - 1 do
            begin
              s := Trim(names[k]);
              if s = '' then Continue;
              i := ZipFind(L, 'content/data/' + s);
              if i >= 0 then CD.Streams[n] := ZipRead(Data, L[i]) else CD.Streams[n] := nil;
              Inc(n);
            end;
            SetLength(CD.Streams, n);
          finally
            names.Free;
          end;
        end;
      end
      else
      begin
        i := ZipFind(L, 'content/riffData.cdr');
        if i >= 0 then CD.Root := ZipRead(Data, L[i]);
      end;
    end
    else CD.Root := Data;
    if (Length(CD.Root) < 12) or (FourCCAt(CD.Root, 0) <> 'RIFF') then
      raise EXVError.Create('CDR: no drawing data');
    CD.SetVersion(GetCdrVersion(CD.Root[11]));
    if CD.Version < 300 then raise EXVError.Create('CDR: unsupported version');

    // pass 1: resources
    SP := TCdrStylesPass.Create;
    try
      SP.Doc := CD;
      WalkRiff(CD, CD.Root, 0, Length(CD.Root), 0, nil, SP.OnChunk, SP.OnList);
    finally
      SP.Free;
    end;
    CD.SetVersion(GetCdrVersion(CD.Root[11]));

    // pass 2: the chosen page (master pages are skipped by their flags)
    PP := TCdrPainter.Create(CD, Doc);
    try
      pw := CD.PageW; ph := CD.PageH;
      if Length(CD.Pages) > 0 then
      begin
        pw := CD.Pages[0].W; ph := CD.Pages[0].H;
      end;
      if (pw < 0.01) or (ph < 0.01) then begin pw := 8.5; ph := 11; end;
      PP.PageW := pw; PP.PageH := ph;
      PP.TargetPage := Max(0, Doc.LoadPage);
      WalkRiff(CD, CD.Root, 0, Length(CD.Root), 0, nil, PP.OnChunk, PP.OnList);
      PP.Flush;
      PP.Finish;
      Doc.SetPageSize(Max(1, PP.PageW * PP.SX), Max(1, PP.PageH * PP.SX));
      Doc.PageCount := Max(1, PP.DrawnPages);
    finally
      PP.Free;
    end;
  finally
    CD.Free;
  end;
end;

initialization
  XVRegisterReader('CDR', 'cdr;cdt;cdx;cmx', XVIsCDR, XVReadCDRDoc);
