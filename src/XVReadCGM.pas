unit XVReadCGM;

{$mode delphi}{$H+}
{$R-}{$Q-}

// XelVectors - Computer Graphics Metafile (CGM) reader, binary encoding
// (ISO/IEC 8632-3, versions 1 to 4) and clear text encoding (8632-4).
//
// The metafile and picture descriptors set the precisions, VDC type and
// extent, colour selection mode and width specification modes; the first
// picture is played: polylines, disjoint polylines, polymarkers, polygons,
// polygon sets, rectangles, circles, circular and elliptical arcs (3 point,
// centre, close types), ellipses, polybeziers, NUBS / NURBS, cell arrays
// (raster images), texts (restricted and appended), figures (closed figures
// that fill as one area), hatches and clip rectangles.

interface

uses
  SysUtils, Classes, Math, XVModel;

function XVIsCGM(const Data: TBytes): Boolean;
procedure XVReadCGMDoc(Doc: TXVDocument; const Data: TBytes);

implementation

type
  TCgmAttrs = record
    LineType: Integer;
    LineWidth: Double;
    LineColor: TXVColor;
    LineCap, LineJoin: Integer;
    MarkerType: Integer;
    MarkerSize: Double;
    MarkerColor: TXVColor;
    TextColor: TXVColor;
    TextFont: Integer;
    CharHeight: Double;
    CharExp, CharSpacing: Double;
    UpX, UpY, BaseX, BaseY: Double;
    TextPath: Integer;
    HAlign, VAlign: Integer;
    Interior: Integer;
    FillColor: TXVColor;
    HatchIndex: Integer;
    EdgeType: Integer;
    EdgeWidth: Double;
    EdgeColor: TXVColor;
    EdgeVisible: Boolean;
    EdgeCap, EdgeJoin: Integer;
  end;

  { TCgmReader }

  TCgmReader = class
    Doc: TXVDocument;
    D: TBytes;
    // parameter window of the current element
    Pp, Pe: Integer;
    // precisions
    IntBits, IdxBits, ColBits, ColIdxBits, VdcIntBits: Integer;
    RealFloat, VdcRealFloat: Boolean;
    RealBits, VdcRealBits: Integer;     // 32 / 64
    VdcReal: Boolean;
    ColDirect: Boolean;
    ColMin, ColMax: array[0..2] of Double;
    LineWidthMode, MarkerSizeMode, EdgeWidthMode: Integer;
    VdcX1, VdcY1, VdcX2, VdcY2: Double;
    HaveExtent: Boolean;
    Palette: array[0..255] of TXVColor;
    Bg: TXVColor;
    Fonts: TStringList;
    A: TCgmAttrs;
    Saved: array of TCgmAttrs;
    // figure / text state
    InFigure: Boolean;
    Fig: TXVPath;
    TextX, TextY: Double;
    TextBuf: string;
    ClipOn, ClipGroup: Boolean;
    ClipX1, ClipY1, ClipX2, ClipY2: Double;
    PictureNo, PicturesDone: Integer;
    Picking: Boolean;
    Defaults: Boolean;
    function U8: Integer;
    function SInt(Bits: Integer): Int64;
    function UInt(Bits: Integer): Int64;
    function Int: Integer;
    function Idx: Integer;
    function Enum: Integer;
    function Real: Double;
    function RealOf(Float: Boolean; Bits: Integer): Double;
    function Vdc: Double;
    procedure Pt(out X, Y: Double);
    function Str: string;
    function Color: TXVColor;
    function ColorIdx(I: Integer): TXVColor;
    function Size(Mode: Integer): Double;
    function Left: Integer;
    function MapPt(X, Y: Double): TXVPoint;
    function Scale: Double;
    procedure Element(Cls, Id: Integer);
    procedure Line(const P: TXVPath);
    procedure Area(const P: TXVPath; Closed: Boolean);
    procedure EmitText(const S: string; Final: Boolean);
    procedure UpdateClip;
    function HatchPaint(Hatch: Integer; C: TXVColor): TXVPaint;
    function Stroke(const T: Integer; W: Double; C: TXVColor; Cap, Join: Integer): TXVStroke;
    procedure CellArray;
    procedure Spline(Rational: Boolean);
    procedure RunBinary;
    procedure RunClearText;
  end;

const
  DEFAULT_COLORS: array[0..15] of Cardinal = (
    $FFFFFF, $000000, $FF0000, $00FF00, $0000FF, $FFFF00, $00FFFF, $FF00FF,
    $808080, $800000, $008000, $000080, $808000, $008080, $800080, $C0C0C0);

function XVIsCGM(const Data: TBytes): Boolean;
var
  w: Integer;
  s: string;
begin
  Result := False;
  if Length(Data) < 4 then Exit;
  // BEGIN METAFILE: class 0, element 1
  w := (Data[0] shl 8) or Data[1];
  if (w shr 5) = $0001 then Exit(True);
  SetLength(s, Min(Length(Data), 64));
  Move(Data[0], s[1], Length(s));
  Result := Pos('BEGMF', UpperCase(s)) > 0;
end;

// ------------------------------ data types ---------------------------------

function TCgmReader.Left: Integer;
begin
  Result := Pe - Pp;
end;

function TCgmReader.U8: Integer;
begin
  if Pp < Pe then Result := D[Pp] else Result := 0;
  Inc(Pp);
end;

function TCgmReader.UInt(Bits: Integer): Int64;
var i: Integer;
begin
  Result := 0;
  for i := 1 to Bits div 8 do Result := (Result shl 8) or U8;
end;

function TCgmReader.SInt(Bits: Integer): Int64;
begin
  Result := UInt(Bits);
  if (Bits < 64) and (Result >= (Int64(1) shl (Bits - 1))) then Result := Result - (Int64(1) shl Bits);
end;

function TCgmReader.Int: Integer;
begin
  Result := SInt(IntBits);
end;

function TCgmReader.Idx: Integer;
begin
  Result := SInt(IdxBits);
end;

function TCgmReader.Enum: Integer;
begin
  Result := SInt(16);
end;

function TCgmReader.RealOf(Float: Boolean; Bits: Integer): Double;
var
  c: Cardinal;
  q: UInt64;
  s: Single;
  whole: Int64;
  frac: Cardinal;
begin
  if Float then
  begin
    if Bits = 64 then
    begin
      q := UInt(64);
      Move(q, Result, 8);
    end
    else
    begin
      c := UInt(32);
      Move(c, s, 4);
      Result := s;
    end;
  end
  else
  begin
    if Bits = 64 then
    begin
      whole := SInt(32);
      frac := UInt(32);
      Result := whole + frac / 4294967296.0;
    end
    else
    begin
      whole := SInt(16);
      frac := UInt(16);
      Result := whole + frac / 65536.0;
    end;
  end;
  if IsNan(Result) or IsInfinite(Result) then Result := 0;
end;

function TCgmReader.Real: Double;
begin
  Result := RealOf(RealFloat, RealBits);
end;

function TCgmReader.Vdc: Double;
begin
  if VdcReal then Result := RealOf(VdcRealFloat, VdcRealBits)
  else Result := SInt(VdcIntBits);
end;

procedure TCgmReader.Pt(out X, Y: Double);
begin
  X := Vdc;
  Y := Vdc;
end;

function TCgmReader.Str: string;
var n, i, l: Integer;
begin
  Result := '';
  n := U8;
  if n = 255 then
  begin
    // long form: 15-bit length chunks with a continuation bit
    repeat
      l := UInt(16);
      for i := 1 to l and $7FFF do Result := Result + Chr(U8);
    until (l and $8000) = 0;
  end
  else
    for i := 1 to n do Result := Result + Chr(U8);
end;

function TCgmReader.ColorIdx(I: Integer): TXVColor;
begin
  if (I >= 0) and (I <= 255) then Result := Palette[I] else Result := XV_BLACK;
end;

function TCgmReader.Color: TXVColor;
var
  v: array[0..2] of Double;
  k: Integer;
begin
  if ColDirect then
  begin
    for k := 0 to 2 do
    begin
      v[k] := UInt(ColBits);
      if ColMax[k] > ColMin[k] then v[k] := (v[k] - ColMin[k]) / (ColMax[k] - ColMin[k]) * 255
      else v[k] := 0;
    end;
    Result := XVRGB(EnsureRange(Round(v[0]), 0, 255), EnsureRange(Round(v[1]), 0, 255), EnsureRange(Round(v[2]), 0, 255));
  end
  else Result := ColorIdx(UInt(ColIdxBits));
end;

// line width, marker size, edge width: absolute (VDC), scaled (real),
// fractional of the extent, or millimetres
function TCgmReader.Size(Mode: Integer): Double;
begin
  case Mode of
    0: Result := Vdc;
    2: Result := Real * Max(Abs(VdcX2 - VdcX1), Abs(VdcY2 - VdcY1));
    3: Result := Real;
  else
    Result := Real;
  end;
end;

// VDC -> document: y up when the extent says so
function TCgmReader.MapPt(X, Y: Double): TXVPoint;
begin
  if VdcX2 >= VdcX1 then Result.X := X - Min(VdcX1, VdcX2) else Result.X := VdcX1 - X;
  if VdcY2 >= VdcY1 then Result.Y := Max(VdcY1, VdcY2) - Y else Result.Y := Y - VdcY2;
end;

function TCgmReader.Scale: Double;
begin
  Result := 1;
end;

// ------------------------------ drawing ------------------------------------

function TCgmReader.Stroke(const T: Integer; W: Double; C: TXVColor; Cap, Join: Integer): TXVStroke;
var u, px: Double;
begin
  Result := XVStroke(C, 0);
  // scaled widths are multiples of a nominal width: about 1/1000 of the extent
  px := Max(Abs(VdcX2 - VdcX1), Abs(VdcY2 - VdcY1)) / 1000;
  case LineWidthMode of
    0: Result.Width := W;
    3: Result.Width := W * px * 4;
  else
    if W <= 1.0001 then Result.Width := 0 else Result.Width := W * px;
  end;
  u := Max(Result.Width, px * 2);
  case T of
    2: Result.Dashes := [6 * u, 3 * u];
    3: Result.Dashes := [u, 2 * u];
    4: Result.Dashes := [6 * u, 2 * u, u, 2 * u];
    5: Result.Dashes := [6 * u, 2 * u, u, 2 * u, u, 2 * u];
  end;
  case Cap of
    2: Result.Cap := lcRound;
    3: Result.Cap := lcSquare;
  else
    Result.Cap := lcButt;
  end;
  case Join of
    2: Result.Join := ljRound;
    3: Result.Join := ljBevel;
  else
    Result.Join := ljMiter;
  end;
end;

procedure TCgmReader.UpdateClip;
var p: TXVPath; a, b: TXVPoint;
begin
  if ClipGroup then
  begin
    Doc.EndGroup;
    ClipGroup := False;
  end;
  if ClipOn and (ClipX2 <> ClipX1) and (ClipY2 <> ClipY1) then
  begin
    a := MapPt(ClipX1, ClipY1); b := MapPt(ClipX2, ClipY2);
    p := Default(TXVPath);
    p.Clear;
    p.AddRect(Min(a.X, b.X), Min(a.Y, b.Y), Abs(b.X - a.X), Abs(b.Y - a.Y));
    Doc.BeginGroup(Doc.AddClip(p, frNonZero), 1);
    ClipGroup := True;
  end;
end;

procedure TCgmReader.Line(const P: TXVPath);
begin
  if P.NCmd = 0 then Exit;
  if InFigure then
  begin
    Fig.Append(P);
    Exit;
  end;
  Doc.AddPath(P, XVNoPaint, Stroke(A.LineType, A.LineWidth, A.LineColor, A.LineCap, A.LineJoin));
end;

function TCgmReader.HatchPaint(Hatch: Integer; C: TXVColor): TXVPaint;
var
  img: TXVImage;
  x, y: Integer;
  on: Boolean;
begin
  img := XVNewImage(8, 8);
  for y := 0 to 7 do
    for x := 0 to 7 do
    begin
      case Hatch of
        1: on := y = 0;
        2: on := x = 0;
        3: on := x = 7 - y;
        4: on := x = y;
        5: on := (x = 0) or (y = 0);
        6: on := (x = y) or (x = 7 - y);
      else
        on := (x = 7 - y);
      end;
      if on then img.Px[y * 8 + x] := C;
    end;
  Result := XVPatternPaint(Doc.AddPattern(Doc.AddImageData(img), TXVMatrix.Identity, True), C);
end;

procedure TCgmReader.Area(const P: TXVPath; Closed: Boolean);
var
  fp: TXVPaint;
  st: TXVStroke;
begin
  if P.NCmd = 0 then Exit;
  if InFigure then
  begin
    Fig.Append(P);
    Exit;
  end;
  case A.Interior of
    1: fp := XVSolid(A.FillColor);
    2, 5: fp := XVSolid(A.FillColor);          // patterns: their colour
    3: fp := HatchPaint(A.HatchIndex, A.FillColor);
    6: fp := XVSolid(A.FillColor);
  else
    fp := XVNoPaint;
  end;
  st := XVNoStroke;
  if A.EdgeVisible then
  begin
    st := Stroke(A.EdgeType, A.EdgeWidth, A.EdgeColor, A.EdgeCap, A.EdgeJoin);
    if EdgeWidthMode = 0 then st.Width := A.EdgeWidth;
  end
  else if A.Interior = 0 then
    // hollow: the boundary in the fill colour
    st := XVStroke(A.FillColor, 0);
  Doc.AddPath(P, fp, st, frEvenOdd);
end;

procedure TCgmReader.EmitText(const S: string; Final: Boolean);
var
  font: TXVFont;
  m: TXVMatrix;
  org: TXVPoint;
  ux, uy, bx, by, h, lu, lb: Double;
  idx: Integer;
  name, u: string;
  t: string;
begin
  TextBuf := TextBuf + S;
  if not Final then Exit;
  t := TextBuf;
  TextBuf := '';
  if t = '' then Exit;
  font := XVDefaultFont;
  if (A.TextFont >= 1) and (A.TextFont <= Fonts.Count) then name := Fonts[A.TextFont - 1] else name := 'Helvetica';
  u := LowerCase(name);
  if (Pos('times', u) > 0) or (Pos('roman', u) > 0) or (Pos('serif', u) > 0) and (Pos('sans', u) = 0) then font.Family := 'Times New Roman'
  else if Pos('courier', u) > 0 then font.Family := 'Courier New'
  else if Pos('symbol', u) > 0 then font.Family := 'Symbol'
  else font.Family := 'Arial';
  font.Weight := 400;
  if Pos('bold', u) > 0 then font.Weight := 700;
  font.Italic := (Pos('italic', u) > 0) or (Pos('oblique', u) > 0);
  h := Abs(A.CharHeight);
  if h <= 0 then h := Max(Abs(VdcY2 - VdcY1), 1) / 50;
  // the character height is the cap height
  font.Size := h * 1.4;
  org := MapPt(TextX, TextY);
  // the up and base vectors give orientation and expansion (y up in VDC)
  ux := A.UpX; uy := A.UpY; bx := A.BaseX; by := A.BaseY;
  lu := Hypot(ux, uy); lb := Hypot(bx, by);
  if lu < 1e-12 then begin ux := 0; uy := 1; lu := 1; end;
  if lb < 1e-12 then begin bx := 1; by := 0; lb := 1; end;
  if VdcY2 < VdcY1 then begin uy := -uy; by := -by; end;
  if VdcX2 < VdcX1 then begin ux := -ux; bx := -bx; end;
  // text space x = base direction, y = down (minus up), both in document space
  m := TXVMatrix.Make(bx / lb * A.CharExp, -by / lb * A.CharExp, -ux / lu, uy / lu, org.X, org.Y);
  idx := Doc.AddText(XVCodePageToUtf8(BytesOf(t), 0, Length(t), 28591), font, m, XVSolid(A.TextColor));
  case A.HAlign of
    2: Doc.Elements[idx].Anchor := taMiddle;
    3: Doc.Elements[idx].Anchor := taEnd;
  end;
  case A.VAlign of
    1, 2: Doc.Elements[idx].Baseline := tbTop;
    3: Doc.Elements[idx].Baseline := tbMiddle;
    5: Doc.Elements[idx].Baseline := tbBottom;
  end;
end;

procedure TCgmReader.CellArray;
var
  px, py, qx, qy, rx, ry: Double;
  nx, ny, prec, mode, x, y, k, run, bits, bitpos, rowStart: Integer;
  img: TXVImage;
  c: TXVColor;
  p, q, r: TXVPoint;
  m: TXVMatrix;

  function Bits_(n: Integer): Cardinal;
  var i: Integer;
  begin
    Result := 0;
    for i := 1 to n do
    begin
      if bitpos = 0 then begin bits := U8; bitpos := 8; end;
      Dec(bitpos);
      Result := (Result shl 1) or Cardinal((bits shr bitpos) and 1);
    end;
  end;

  function CellColor: TXVColor;
  var v: array[0..2] of Double; kk: Integer;
  begin
    if ColDirect then
    begin
      for kk := 0 to 2 do
      begin
        v[kk] := Bits_(prec);
        if ColMax[kk] > ColMin[kk] then v[kk] := (v[kk] - ColMin[kk]) / (ColMax[kk] - ColMin[kk]) * 255
        else v[kk] := v[kk] * 255 / Max(1, (1 shl prec) - 1);
      end;
      Result := XVRGB(EnsureRange(Round(v[0]), 0, 255), EnsureRange(Round(v[1]), 0, 255), EnsureRange(Round(v[2]), 0, 255));
    end
    else Result := ColorIdx(Bits_(prec));
  end;

begin
  Pt(px, py); Pt(qx, qy); Pt(rx, ry);
  nx := Int; ny := Int;
  prec := Int;
  mode := Enum;
  if prec = 0 then
  begin
    if ColDirect then prec := ColBits else prec := ColIdxBits;
  end;
  if (nx <= 0) or (ny <= 0) or (Int64(nx) * ny > 40000000) then Exit;
  img := XVNewImage(nx, ny);
  bitpos := 0;
  for y := 0 to ny - 1 do
  begin
    // rows start on 16-bit boundaries
    if bitpos <> 0 then bitpos := 0;
    rowStart := Pp;
    if ((Pp - rowStart) and 1) <> 0 then ;
    x := 0;
    if mode = 0 then
    begin
      while x < nx do
      begin
        run := Int;
        c := CellColor;
        bitpos := 0;
        for k := 0 to run - 1 do
        begin
          if x >= nx then Break;
          img.Px[y * nx + x] := c;
          Inc(x);
        end;
        if Left <= 0 then Break;
      end;
    end
    else
      for x := 0 to nx - 1 do img.Px[y * nx + x] := CellColor;
    bitpos := 0;
    if Odd(Pp - rowStart) then Inc(Pp);
    if Left <= 0 then Break;
  end;
  p := MapPt(px, py); q := MapPt(qx, qy); r := MapPt(rx, ry);
  // P: first cell corner, R: end of the first row, Q: the opposite corner
  m := TXVMatrix.Make((r.X - p.X) / nx, (r.Y - p.Y) / nx, (q.X - r.X) / ny, (q.Y - r.Y) / ny, p.X, p.Y);
  Doc.AddImage(Doc.AddImageData(img), m, 1);
end;

// NUBS / NURBS: order, control points, knots, parameter range [, weights]
procedure TCgmReader.Spline(Rational: Boolean);
var
  order, n, i, j, k, steps, r: Integer;
  cx, cy, kn, w: TXVDoubles;
  t0, t1, t, x, y, a, den: Double;
  p: TXVPath;
  q: TXVPoint;
  dx, dy, dw: array of Double;
begin
  order := Int;
  n := Int;
  if (order < 2) or (n < order) or (n > 100000) then Exit;
  SetLength(cx, n); SetLength(cy, n);
  for i := 0 to n - 1 do Pt(cx[i], cy[i]);
  SetLength(kn, n + order);
  for i := 0 to n + order - 1 do kn[i] := Real;
  t0 := Real; t1 := Real;
  SetLength(w, n);
  for i := 0 to n - 1 do if Rational then w[i] := Real else w[i] := 1;
  if t1 <= t0 then begin t0 := kn[order - 1]; t1 := kn[n]; end;
  p := Default(TXVPath);
  p.Clear;
  steps := Max(16, n * 10);
  SetLength(dx, order); SetLength(dy, order); SetLength(dw, order);
  for i := 0 to steps do
  begin
    t := t0 + (t1 - t0) * i / steps;
    if i = steps then t := t1 - (t1 - t0) * 1e-9;
    // span
    k := order - 1;
    while (k < n - 1) and (kn[k + 1] <= t) do Inc(k);
    for j := 0 to order - 1 do
    begin
      r := EnsureRange(k - order + 1 + j, 0, n - 1);
      dw[j] := w[r]; dx[j] := cx[r] * w[r]; dy[j] := cy[r] * w[r];
    end;
    for r := 1 to order - 1 do
      for j := order - 1 downto r do
      begin
        den := kn[j + 1 + k - r] - kn[j + k - order + 1];
        if Abs(den) < 1e-300 then a := 0 else a := (t - kn[j + k - order + 1]) / den;
        dx[j] := (1 - a) * dx[j - 1] + a * dx[j];
        dy[j] := (1 - a) * dy[j - 1] + a * dy[j];
        dw[j] := (1 - a) * dw[j - 1] + a * dw[j];
      end;
    if Abs(dw[order - 1]) < 1e-300 then Continue;
    x := dx[order - 1] / dw[order - 1]; y := dy[order - 1] / dw[order - 1];
    q := MapPt(x, y);
    if i = 0 then p.MoveTo(q.X, q.Y) else p.LineTo(q.X, q.Y);
  end;
  Line(p);
end;

procedure TCgmReader.Element(Cls, Id: Integer);
var
  i, n, k, cont, f: Integer;
  x, y, x2, y2, x3, y3, r, dx1, dy1, dx2, dy2, a1, a2, sw, det, t0, t1: Double;
  p: TXVPath;
  q, q2, q3: TXVPoint;
  s: string;
  pts: array of TXVPoint;


  procedure AddVdcPt(var P_: TXVPath; Mv: Boolean);
  var vx, vy: Double; mp: TXVPoint;
  begin
    Pt(vx, vy);
    mp := MapPt(vx, vy);
    if Mv then P_.MoveTo(mp.X, mp.Y) else P_.LineTo(mp.X, mp.Y);
  end;

  // circle through 3 points: centre and radius (VDC)
  function Circle3(ax, ay, bx, by, cx, cy: Double; out ox, oy, rr: Double): Boolean;
  var dd: Double;
  begin
    dd := 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by));
    Result := Abs(dd) > 1e-12;
    if not Result then Exit;
    ox := ((ax * ax + ay * ay) * (by - cy) + (bx * bx + by * by) * (cy - ay) + (cx * cx + cy * cy) * (ay - by)) / dd;
    oy := ((ax * ax + ay * ay) * (cx - bx) + (bx * bx + by * by) * (ax - cx) + (cx * cx + cy * cy) * (bx - ax)) / dd;
    rr := Hypot(ax - ox, ay - oy);
  end;

  // arc in VDC space (counter-clockwise, y up) mapped point by point
  procedure ArcVdc(var P_: TXVPath; cx, cy, rx1, ry1, rx2, ry2, t0, sweep: Double; Lead: Integer);
  var nn, j: Integer; tt: Double; mp: TXVPoint;
  begin
    nn := Max(8, Ceil(Abs(sweep) / (Pi / 32)));
    for j := 0 to nn do
    begin
      tt := t0 + sweep * j / nn;
      mp := MapPt(cx + rx1 * Cos(tt) + rx2 * Sin(tt), cy + ry1 * Cos(tt) + ry2 * Sin(tt));
      if (j = 0) and (Lead = 1) then P_.MoveTo(mp.X, mp.Y) else P_.LineTo(mp.X, mp.Y);
    end;
  end;

  function SweepCCW(u1x, u1y, u2x, u2y: Double): Double;
  begin
    Result := ArcTan2(u2y, u2x) - ArcTan2(u1y, u1x);
    while Result <= 1e-12 do Result := Result + 2 * Pi;
  end;

begin
  p := Default(TXVPath);
  p.Clear;
  case Cls of
    0:
      case Id of
        3: begin                       // BEGIN PICTURE
             Inc(PictureNo);
             Picking := PicturesDone = Doc.LoadPage;
           end;
        5: begin                       // END PICTURE
             if Picking then
             begin
               if ClipGroup then begin Doc.EndGroup; ClipGroup := False; end;
             end;
             Inc(PicturesDone);
             Picking := False;
           end;
        8: if Picking then begin InFigure := True; Fig.Clear; end;     // BEGIN FIGURE
        9: if Picking then                                             // END FIGURE
           begin
             InFigure := False;
             Fig.Close;
             Area(Fig, True);
             Fig.Clear;
           end;
      end;
    1:
      case Id of
        3: VdcReal := Enum = 1;
        4: IntBits := Max(8, Int);
        5: begin
             f := Enum;
             a1 := Int; a2 := Int;
             RealFloat := f = 0;
             if RealFloat then begin if a1 >= 12 then RealBits := 64 else RealBits := 32; end
             else begin if a1 >= 32 then RealBits := 64 else RealBits := 32; end;
           end;
        6: IdxBits := Max(8, Int);
        7: ColBits := Max(1, Int);
        8: ColIdxBits := Max(8, Int);
        10: begin
              if ColDirect or True then
              begin
                for k := 0 to 2 do ColMin[k] := UInt(ColBits);
                for k := 0 to 2 do ColMax[k] := UInt(ColBits);
              end;
            end;
        12: begin                      // METAFILE DEFAULTS REPLACEMENT: nested elements
              Defaults := True;
            end;
        13: begin                      // FONT LIST
              Fonts.Clear;
              while Left > 0 do Fonts.Add(Str);
            end;
      end;
    2:
      case Id of
        2: ColDirect := Enum = 1;
        3: LineWidthMode := Enum;
        4: MarkerSizeMode := Enum;
        5: EdgeWidthMode := Enum;
        6: begin
             Pt(VdcX1, VdcY1); Pt(VdcX2, VdcY2);
             HaveExtent := (VdcX1 <> VdcX2) and (VdcY1 <> VdcY2);
           end;
        7: begin
             if ColDirect then Bg := Color
             else Bg := Color;
           end;
      end;
    3:
      case Id of
        1: VdcIntBits := Max(16, Int);
        2: begin
             f := Enum;
             a1 := Int; a2 := Int;
             VdcRealFloat := f = 0;
             if VdcRealFloat then begin if a1 >= 12 then VdcRealBits := 64 else VdcRealBits := 32; end
             else begin if a1 >= 32 then VdcRealBits := 64 else VdcRealBits := 32; end;
           end;
        5: begin
             Pt(ClipX1, ClipY1); Pt(ClipX2, ClipY2);
             if Picking then UpdateClip;
           end;
        6: begin
             ClipOn := Enum = 1;
             if Picking then UpdateClip;
           end;
        11: begin SetLength(Saved, Length(Saved) + 1); Saved[High(Saved)] := A; end;
        12: if Length(Saved) > 0 then begin A := Saved[High(Saved)]; SetLength(Saved, Length(Saved) - 1); end;
      end;
    4:
      if Picking then
        case Id of
          1: begin                     // POLYLINE
               i := 0;
               while Left >= 2 * (VdcIntBits div 8) do
               begin
                 AddVdcPt(p, i = 0);
                 Inc(i);
                 if VdcReal and (Left < 2 * (VdcRealBits div 8)) then Break;
               end;
               Line(p);
             end;
          2: begin                     // DISJOINT POLYLINE
               while Left > 0 do
               begin
                 AddVdcPt(p, True);
                 if Left <= 0 then Break;
                 AddVdcPt(p, False);
               end;
               Line(p);
             end;
          3: begin                     // POLYMARKER
               while Left > 0 do
               begin
                 Pt(x, y);
                 q := MapPt(x, y);
                 r := Max(A.MarkerSize, 1) / 2;
                 if MarkerSizeMode <> 0 then r := Max(Abs(VdcX2 - VdcX1), Abs(VdcY2 - VdcY1)) / 200 * Max(A.MarkerSize, 1);
                 p.Clear;
                 case A.MarkerType of
                   1: p.AddEllipse(q.X, q.Y, r / 4, r / 4);
                   2: begin p.MoveTo(q.X - r, q.Y); p.LineTo(q.X + r, q.Y); p.MoveTo(q.X, q.Y - r); p.LineTo(q.X, q.Y + r); end;
                   3: begin
                        p.MoveTo(q.X - r, q.Y); p.LineTo(q.X + r, q.Y); p.MoveTo(q.X, q.Y - r); p.LineTo(q.X, q.Y + r);
                        p.MoveTo(q.X - r * 0.7, q.Y - r * 0.7); p.LineTo(q.X + r * 0.7, q.Y + r * 0.7);
                        p.MoveTo(q.X - r * 0.7, q.Y + r * 0.7); p.LineTo(q.X + r * 0.7, q.Y - r * 0.7);
                      end;
                   4: p.AddEllipse(q.X, q.Y, r, r);
                 else
                   begin p.MoveTo(q.X - r, q.Y - r); p.LineTo(q.X + r, q.Y + r); p.MoveTo(q.X - r, q.Y + r); p.LineTo(q.X + r, q.Y - r); end;
                 end;
                 if A.MarkerType = 1 then Doc.AddPath(p, XVSolid(A.MarkerColor), XVNoStroke)
                 else Doc.AddPath(p, XVNoPaint, XVStroke(A.MarkerColor, 0));
               end;
             end;
          4: begin                     // TEXT
               Pt(TextX, TextY);
               f := Enum;
               s := Str;
               EmitText(s, f = 1);
             end;
          5: begin                     // RESTRICTED TEXT
               Vdc; Vdc;
               Pt(TextX, TextY);
               f := Enum;
               s := Str;
               EmitText(s, f = 1);
             end;
          6: begin                     // APPEND TEXT
               f := Enum;
               s := Str;
               EmitText(s, f = 1);
             end;
          7: begin                     // POLYGON
               i := 0;
               while Left > 0 do
               begin
                 AddVdcPt(p, i = 0);
                 Inc(i);
               end;
               p.Close;
               Area(p, True);
             end;
          8: begin                     // POLYGON SET: points with edge flags
               i := 0;
               k := 0;
               while Left > 0 do
               begin
                 Pt(x, y);
                 f := Enum;
                 q := MapPt(x, y);
                 if k = 0 then p.MoveTo(q.X, q.Y) else p.LineTo(q.X, q.Y);
                 Inc(k);
                 if f >= 2 then begin p.Close; k := 0; end;
                 Inc(i);
               end;
               p.Close;
               Area(p, True);
             end;
          9: CellArray;
          11: begin                    // RECTANGLE
                Pt(x, y); Pt(x2, y2);
                q := MapPt(x, y); q2 := MapPt(x2, y2);
                p.AddRect(Min(q.X, q2.X), Min(q.Y, q2.Y), Abs(q2.X - q.X), Abs(q2.Y - q.Y));
                Area(p, True);
              end;
          12: begin                    // CIRCLE
                Pt(x, y);
                r := Vdc;
                q := MapPt(x, y);
                p.AddEllipse(q.X, q.Y, Abs(r), Abs(r));
                Area(p, True);
              end;
          13, 14: begin                // CIRCULAR ARC 3 POINT [CLOSE]
                Pt(x, y); Pt(x2, y2); Pt(x3, y3);
                if Id = 14 then f := Enum else f := -1;
                if Circle3(x, y, x2, y2, x3, y3, dx1, dy1, r) then
                begin
                  a1 := ArcTan2(y - dy1, x - dx1);
                  a2 := ArcTan2(y3 - dy1, x3 - dx1);
                  sw := a2 - a1;
                  // through the middle point
                  a2 := ArcTan2(y2 - dy1, x2 - dx1) - a1;
                  while a2 < 0 do a2 := a2 + 2 * Pi;
                  while sw < 0 do sw := sw + 2 * Pi;
                  if a2 > sw then sw := sw - 2 * Pi;
                  ArcVdc(p, dx1, dy1, r, 0, 0, r, a1, sw, 1);
                end
                else
                begin
                  q := MapPt(x, y); q3 := MapPt(x3, y3);
                  p.MoveTo(q.X, q.Y); p.LineTo(q3.X, q3.Y);
                end;
                if Id = 14 then
                begin
                  if f = 0 then begin q := MapPt(dx1, dy1); p.LineTo(q.X, q.Y); end;
                  p.Close;
                  Area(p, True);
                end
                else Line(p);
              end;
          15, 16, 20: begin            // CIRCULAR ARC CENTRE [CLOSE] [REVERSED]
                Pt(x, y);
                dx1 := Vdc; dy1 := Vdc; dx2 := Vdc; dy2 := Vdc;
                r := Vdc;
                sw := SweepCCW(dx1, dy1, dx2, dy2);
                if Id = 20 then sw := sw - 2 * Pi;
                ArcVdc(p, x, y, r, 0, 0, r, ArcTan2(dy1, dx1), sw, 1);
                if Id = 16 then
                begin
                  f := Enum;
                  if f = 0 then begin q := MapPt(x, y); p.LineTo(q.X, q.Y); end;
                  p.Close;
                  Area(p, True);
                end
                else Line(p);
              end;
          17: begin                    // ELLIPSE: centre, two conjugate diameter ends
                Pt(x, y); Pt(x2, y2); Pt(x3, y3);
                ArcVdc(p, x, y, x2 - x, y2 - y, x3 - x, y3 - y, 0, 2 * Pi, 1);
                p.Close;
                Area(p, True);
              end;
          18, 19: begin                // ELLIPTICAL ARC [CLOSE]
                Pt(x, y); Pt(x2, y2); Pt(x3, y3);
                dx1 := Vdc; dy1 := Vdc; dx2 := Vdc; dy2 := Vdc;
                // the start / end vectors as cos / sin of the conjugate diameters
                det := (x2 - x) * (y3 - y) - (x3 - x) * (y2 - y);
                if Abs(det) < 1e-300 then det := 1;
                t0 := ArcTan2((-(y2 - y) * dx1 + (x2 - x) * dy1) / det, ((y3 - y) * dx1 - (x3 - x) * dy1) / det);
                t1 := ArcTan2((-(y2 - y) * dx2 + (x2 - x) * dy2) / det, ((y3 - y) * dx2 - (x3 - x) * dy2) / det);
                sw := t1 - t0;
                while sw <= 1e-12 do sw := sw + 2 * Pi;
                // counter-clockwise in VDC runs backwards when the frame is mirrored
                if det < 0 then sw := sw - 2 * Pi;
                ArcVdc(p, x, y, x2 - x, y2 - y, x3 - x, y3 - y, t0, sw, 1);
                if Id = 19 then
                begin
                  f := Enum;
                  if f = 0 then begin q := MapPt(x, y); p.LineTo(q.X, q.Y); end;
                  p.Close;
                  Area(p, True);
                end
                else Line(p);
              end;
          24, 25: Spline(Id = 25);
          26: begin                    // POLYBEZIER: continuity, points
                cont := Idx;
                n := 0;
                SetLength(pts, 0);
                while Left > 0 do
                begin
                  Pt(x, y);
                  SetLength(pts, n + 1);
                  pts[n] := MapPt(x, y);
                  Inc(n);
                end;
                i := 0;
                while i + 3 < n do
                begin
                  if (cont = 1) or (i = 0) then p.MoveTo(pts[i].X, pts[i].Y);
                  p.CubicTo(pts[i + 1].X, pts[i + 1].Y, pts[i + 2].X, pts[i + 2].Y, pts[i + 3].X, pts[i + 3].Y);
                  if cont = 1 then Inc(i, 4) else Inc(i, 3);
                end;
                Line(p);
              end;
        end;
    5:
      case Id of
        2: A.LineType := Idx;
        3: A.LineWidth := Size(LineWidthMode);
        4: A.LineColor := Color;
        6: A.MarkerType := Idx;
        7: A.MarkerSize := Size(MarkerSizeMode);
        8: A.MarkerColor := Color;
        10: A.TextFont := Idx;
        12: A.CharExp := Real;
        13: A.CharSpacing := Real;
        14: A.TextColor := Color;
        15: A.CharHeight := Vdc;
        16: begin A.UpX := Vdc; A.UpY := Vdc; A.BaseX := Vdc; A.BaseY := Vdc; end;
        17: A.TextPath := Enum;
        18: begin A.HAlign := Enum; A.VAlign := Enum; end;
        22: A.Interior := Enum;
        23: A.FillColor := Color;
        24: A.HatchIndex := Idx;
        27: A.EdgeType := Idx;
        28: A.EdgeWidth := Size(EdgeWidthMode);
        29: A.EdgeColor := Color;
        30: A.EdgeVisible := Enum = 1;
        34: begin                      // COLOUR TABLE
              k := UInt(ColIdxBits);
              while (Left >= 3 * (ColBits div 8)) and (k <= 255) do
              begin
                Palette[k] := XVRGB(0, 0, 0);
                begin
                  dx1 := UInt(ColBits); dy1 := UInt(ColBits); dx2 := UInt(ColBits);
                  if ColMax[0] > ColMin[0] then dx1 := (dx1 - ColMin[0]) / (ColMax[0] - ColMin[0]) * 255;
                  if ColMax[1] > ColMin[1] then dy1 := (dy1 - ColMin[1]) / (ColMax[1] - ColMin[1]) * 255;
                  if ColMax[2] > ColMin[2] then dx2 := (dx2 - ColMin[2]) / (ColMax[2] - ColMin[2]) * 255;
                  Palette[k] := XVRGB(EnsureRange(Round(dx1), 0, 255), EnsureRange(Round(dy1), 0, 255),
                    EnsureRange(Round(dx2), 0, 255));
                end;
                Inc(k);
              end;
            end;
        37: begin A.LineCap := Idx; Idx; end;
        38: A.LineJoin := Idx;
        44: begin A.EdgeCap := Idx; Idx; end;
        45: A.EdgeJoin := Idx;
      end;
  end;
end;

procedure TCgmReader.RunBinary;
var
  q, w, cls, id, len, ln, total: Integer;
  buf: TBytes;
  more: Boolean;
  outerP, outerE: Integer;
  saveD: TBytes;
begin
  q := 0;
  while q + 2 <= Length(D) do
  begin
    w := (D[q] shl 8) or D[q + 1];
    Inc(q, 2);
    cls := w shr 12;
    id := (w shr 5) and $7F;
    len := w and $1F;
    if len = 31 then
    begin
      // long form, possibly in partitions
      if q + 2 > Length(D) then Break;
      ln := (D[q] shl 8) or D[q + 1];
      Inc(q, 2);
      more := (ln and $8000) <> 0;
      len := ln and $7FFF;
      if more then
      begin
        SetLength(buf, 0);
        total := 0;
        repeat
          if q + len > Length(D) then len := Length(D) - q;
          SetLength(buf, total + len);
          if len > 0 then Move(D[q], buf[total], len);
          Inc(total, len);
          Inc(q, len + (len and 1));
          if not more then Break;
          if q + 2 > Length(D) then Break;
          ln := (D[q] shl 8) or D[q + 1];
          Inc(q, 2);
          more := (ln and $8000) <> 0;
          len := ln and $7FFF;
        until False;
        saveD := D;
        D := buf;
        Pp := 0; Pe := total;
        try
          Element(cls, id);
        except
        end;
        D := saveD;
        Continue;
      end;
    end;
    if q + len > Length(D) then len := Length(D) - q;
    Pp := q; Pe := q + len;
    outerP := Pp; outerE := Pe;
    try
      Element(cls, id);
    except
      // a malformed element is skipped
    end;
    if Defaults and (cls = 1) and (id = 12) then
    begin
      // the replaced defaults are elements inside this one
      Defaults := False;
      saveD := D;
      SetLength(buf, outerE - outerP);
      if Length(buf) > 0 then Move(D[outerP], buf[0], Length(buf));
      D := buf;
      RunBinary;
      D := saveD;
    end;
    Inc(q, len + (len and 1));
    if (cls = 0) and (id = 2) then Break;          // END METAFILE
  end;
end;

// Clear text encoding: the common subset (descriptors, attributes and the
// primitives with point lists)
procedure TCgmReader.RunClearText;
var
  s: string;
  i, n: Integer;
  stmts: TStringList;
  st, cmd, args: string;
  nums: array of Double;
  p: TXVPath;
  q, q2: TXVPoint;
  inStr: Char;
  cur: string;

  procedure Nums_(const T: string);
  var k: Integer; tok: string;
  begin
    nums := nil;
    tok := '';
    for k := 1 to Length(T) + 1 do
      if (k > Length(T)) or (T[k] in [' ', ',', '(', ')', #9, #10, #13]) then
      begin
        if (tok <> '') and (tok[1] in ['0'..'9', '-', '+', '.']) then
        begin
          SetLength(nums, Length(nums) + 1);
          nums[High(nums)] := XVStrToFloat(tok, 0);
        end;
        tok := '';
      end
      else tok := tok + T[k];
  end;

  function QuotedStr_(const T: string): string;
  var a, b: Integer;
  begin
    a := Pos('"', T); if a = 0 then a := Pos('''', T);
    if a = 0 then Exit('');
    b := Length(T);
    while (b > a) and not (T[b] in ['"', '''']) do Dec(b);
    Result := Copy(T, a + 1, b - a - 1);
  end;

  function Col(k: Integer): TXVColor;
  begin
    if ColDirect then
    begin
      if k + 2 > High(nums) then Exit(XV_BLACK);
      Result := XVRGB(EnsureRange(Round(nums[k] / Max(ColMax[0], 1) * 255), 0, 255),
        EnsureRange(Round(nums[k + 1] / Max(ColMax[1], 1) * 255), 0, 255),
        EnsureRange(Round(nums[k + 2] / Max(ColMax[2], 1) * 255), 0, 255));
    end
    else if k <= High(nums) then Result := ColorIdx(Round(nums[k]))
    else Result := XV_BLACK;
  end;

begin
  SetLength(s, Length(D));
  if Length(D) > 0 then Move(D[0], s[1], Length(D));
  stmts := TStringList.Create;
  try
    // statements end with ";" or "/" outside of strings
    cur := '';
    inStr := #0;
    for i := 1 to Length(s) do
    begin
      if inStr <> #0 then
      begin
        cur := cur + s[i];
        if s[i] = inStr then inStr := #0;
      end
      else if s[i] in ['"', ''''] then begin inStr := s[i]; cur := cur + s[i]; end
      else if s[i] in [';', '/'] then begin stmts.Add(Trim(cur)); cur := ''; end
      else cur := cur + s[i];
    end;
    ColMax[0] := 255; ColMax[1] := 255; ColMax[2] := 255;
    for i := 0 to stmts.Count - 1 do
    begin
      st := stmts[i];
      n := 1;
      while (n <= Length(st)) and not (st[n] in [' ', #9, #10, #13]) do Inc(n);
      cmd := UpperCase(Copy(st, 1, n - 1));
      args := Copy(st, n, MaxInt);
      Nums_(args);
      p := Default(TXVPath);
      p.Clear;
      if cmd = 'BEGPIC' then begin Inc(PictureNo); Picking := PicturesDone = Doc.LoadPage; end
      else if cmd = 'ENDPIC' then begin Inc(PicturesDone); Picking := False; end
      else if cmd = 'VDCEXT' then
      begin
        if Length(nums) >= 4 then
        begin
          VdcX1 := nums[0]; VdcY1 := nums[1]; VdcX2 := nums[2]; VdcY2 := nums[3];
          HaveExtent := True;
        end;
      end
      else if cmd = 'COLRMODE' then ColDirect := Pos('DIRECT', UpperCase(args)) > 0
      else if cmd = 'COLRVALUEEXT' then
      begin
        if Length(nums) >= 6 then begin ColMax[0] := nums[3]; ColMax[1] := nums[4]; ColMax[2] := nums[5]; end;
      end
      else if cmd = 'COLRTABLE' then
      begin
        if Length(nums) >= 4 then
          for n := 0 to (Length(nums) - 1) div 3 - 1 do
            if Round(nums[0]) + n <= 255 then
              Palette[Round(nums[0]) + n] := XVRGB(EnsureRange(Round(nums[1 + 3 * n] / Max(ColMax[0], 1) * 255), 0, 255),
                EnsureRange(Round(nums[2 + 3 * n] / Max(ColMax[1], 1) * 255), 0, 255),
                EnsureRange(Round(nums[3 + 3 * n] / Max(ColMax[2], 1) * 255), 0, 255));
      end
      else if cmd = 'LINECOLR' then A.LineColor := Col(0)
      else if cmd = 'FILLCOLR' then A.FillColor := Col(0)
      else if cmd = 'EDGECOLR' then A.EdgeColor := Col(0)
      else if cmd = 'TEXTCOLR' then A.TextColor := Col(0)
      else if cmd = 'LINEWIDTH' then begin if Length(nums) > 0 then A.LineWidth := nums[0]; end
      else if cmd = 'LINETYPE' then begin if Length(nums) > 0 then A.LineType := Round(nums[0]); end
      else if cmd = 'CHARHEIGHT' then begin if Length(nums) > 0 then A.CharHeight := nums[0]; end
      else if cmd = 'INTSTYLE' then
      begin
        if Pos('SOLID', UpperCase(args)) > 0 then A.Interior := 1
        else if Pos('HOLLOW', UpperCase(args)) > 0 then A.Interior := 0
        else if Pos('HATCH', UpperCase(args)) > 0 then A.Interior := 3
        else if Pos('EMPTY', UpperCase(args)) > 0 then A.Interior := 4;
      end
      else if cmd = 'EDGEVIS' then A.EdgeVisible := Pos('ON', UpperCase(args)) > 0
      else if not Picking then Continue
      else if (cmd = 'LINE') or (cmd = 'POLYGON') then
      begin
        for n := 0 to Length(nums) div 2 - 1 do
        begin
          q := MapPt(nums[2 * n], nums[2 * n + 1]);
          if n = 0 then p.MoveTo(q.X, q.Y) else p.LineTo(q.X, q.Y);
        end;
        if cmd = 'LINE' then Line(p) else begin p.Close; Area(p, True); end;
      end
      else if cmd = 'RECT' then
      begin
        if Length(nums) >= 4 then
        begin
          q := MapPt(nums[0], nums[1]); q2 := MapPt(nums[2], nums[3]);
          p.AddRect(Min(q.X, q2.X), Min(q.Y, q2.Y), Abs(q2.X - q.X), Abs(q2.Y - q.Y));
          Area(p, True);
        end;
      end
      else if cmd = 'CIRCLE' then
      begin
        if Length(nums) >= 3 then
        begin
          q := MapPt(nums[0], nums[1]);
          p.AddEllipse(q.X, q.Y, Abs(nums[2]), Abs(nums[2]));
          Area(p, True);
        end;
      end
      else if cmd = 'TEXT' then
      begin
        if Length(nums) >= 2 then
        begin
          TextX := nums[0]; TextY := nums[1];
          EmitText(QuotedStr_(args), True);
        end;
      end;
    end;
  finally
    stmts.Free;
  end;
end;

procedure XVReadCGMDoc(Doc: TXVDocument; const Data: TBytes);
var
  R: TCgmReader;
  i: Integer;
  w, h: Double;
  s: string;
begin
  R := TCgmReader.Create;
  try
    R.Doc := Doc;
    R.D := Data;
    R.Fonts := TStringList.Create;
    R.IntBits := 16; R.IdxBits := 16; R.ColBits := 8; R.ColIdxBits := 8; R.VdcIntBits := 16;
    R.RealFloat := False; R.RealBits := 32; R.VdcRealFloat := False; R.VdcRealBits := 32;
    for i := 0 to 2 do begin R.ColMin[i] := 0; R.ColMax[i] := 255; end;
    for i := 0 to 255 do
      if i <= High(DEFAULT_COLORS) then R.Palette[i] := $FF000000 or DEFAULT_COLORS[i] else R.Palette[i] := XV_BLACK;
    R.Bg := XV_WHITE;
    R.VdcX1 := 0; R.VdcY1 := 0; R.VdcX2 := 32767; R.VdcY2 := 32767;
    R.LineWidthMode := 1; R.MarkerSizeMode := 1; R.EdgeWidthMode := 1;
    with R.A do
    begin
      LineType := 1; LineWidth := 1; LineColor := XV_BLACK;
      MarkerType := 3; MarkerSize := 1; MarkerColor := XV_BLACK;
      TextColor := XV_BLACK; TextFont := 1; CharExp := 1;
      UpX := 0; UpY := 1; BaseX := 1; BaseY := 0;
      Interior := 0; FillColor := XV_BLACK; HatchIndex := 1;
      EdgeType := 1; EdgeWidth := 1; EdgeColor := XV_BLACK; EdgeVisible := False;
    end;
    R.PictureNo := 0;
    R.PicturesDone := 0;
    R.Fig.Clear;
    SetLength(s, Min(Length(Data), 64));
    if Length(s) > 0 then Move(Data[0], s[1], Length(s));
    if Pos('BEGMF', UpperCase(s)) > 0 then R.RunClearText else R.RunBinary;
    if R.ClipGroup then Doc.EndGroup;
    Doc.PageCount := Max(1, R.PicturesDone);
    // the VDC extent is the picture
    w := Abs(R.VdcX2 - R.VdcX1); h := Abs(R.VdcY2 - R.VdcY1);
    if (w <= 0) or (h <= 0) then begin w := 100; h := 100; end;
    Doc.ViewBox := XVRect(0, 0, w, h);
    // sizes: the longer side about 800 pixels
    Doc.Width := w / Max(w, h) * 800;
    Doc.Height := h / Max(w, h) * 800;
    Doc.Background := R.Bg;
  finally
    R.Fonts.Free;
    R.Free;
  end;
end;

initialization
  XVRegisterReader('CGM', 'cgm', XVIsCGM, XVReadCGMDoc);
end.
