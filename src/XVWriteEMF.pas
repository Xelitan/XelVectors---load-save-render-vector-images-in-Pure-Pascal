unit XVWriteEMF;

{$mode delphi}{$H+}
{$R-}{$Q-}

// XelVectors - Enhanced Metafile (EMF) writer.
//
// Coordinates are written for a reference device of 1536 dpi (1/16 pixel),
// so paths keep sub-pixel precision in 32-bit integers. Paths become
// BEGINPATH .. ENDPATH brackets with POLYLINETO / POLYBEZIERTO and are filled
// and stroked with solid brushes and geometric pens (caps, joins, user dash
// styles). Gradients are written as colour bands inside a clip path (the
// format has no general gradient brush), image patterns as DIB pattern
// brushes, clip groups as SAVEDC / SELECTCLIPPATH / RESTOREDC, texts and
// images under SETWORLDTRANSFORM (any rotation, scale or skew), images with
// transparency through ALPHABLEND. EMF has no translucency for vector
// drawing: translucent colours are written opaque, invisible ones skipped.

interface

uses
  SysUtils, Classes, Math, XVModel;

procedure XVWriteEMFDoc(Doc: TXVDocument; Stream: TStream);

implementation

const
  EMR_HEADER = 1;
  EMR_POLYGON = 3;
  EMR_POLYBEZIERTO = 5;
  EMR_POLYLINETO = 6;
  EMR_EOF = 14;
  EMR_SETBKMODE = 18;
  EMR_SETPOLYFILLMODE = 19;
  EMR_SETSTRETCHBLTMODE = 21;
  EMR_SETTEXTALIGN = 22;
  EMR_SETTEXTCOLOR = 24;
  EMR_MOVETOEX = 27;
  EMR_SAVEDC = 33;
  EMR_RESTOREDC = 34;
  EMR_SETWORLDTRANSFORM = 35;
  EMR_SELECTOBJECT = 37;
  EMR_CREATEBRUSHINDIRECT = 39;
  EMR_DELETEOBJECT = 40;
  EMR_SETMITERLIMIT = 58;
  EMR_BEGINPATH = 59;
  EMR_ENDPATH = 60;
  EMR_CLOSEFIGURE = 61;
  EMR_FILLPATH = 62;
  EMR_STROKEANDFILLPATH = 63;
  EMR_STROKEPATH = 64;
  EMR_SELECTCLIPPATH = 67;
  EMR_STRETCHDIBITS = 81;
  EMR_EXTCREATEFONTINDIRECTW = 82;
  EMR_EXTTEXTOUTW = 84;
  EMR_CREATEDIBPATTERNBRUSHPT = 94;
  EMR_EXTCREATEPEN = 95;
  EMR_ALPHABLEND = 114;

  NULL_BRUSH = $80000005;
  NULL_PEN = $80000008;
  DEFAULT_FONT = $8000000E;

  H_BRUSH = 1;
  H_PEN = 2;
  H_FONT = 3;

  SUB = 16;                         // logical units per pixel

type
  { TEmfOut }

  TEmfOut = class
  private
    S: TMemoryStream;
    Doc: TXVDocument;
    RecCount: Integer;
    RecStart: Int64;
    T: TXVMatrix;                    // document -> logical
    BoundsL, BoundsT, BoundsR, BoundsB: Integer;
    procedure W32(V: Cardinal);
    procedure WI(V: Integer);
    procedure W16(V: Word);
    procedure W8(V: Byte);
    procedure WF(V: Single);
    procedure Pad4;
    procedure BeginRec(AType: Cardinal);
    procedure EndRec;
    procedure Rec0(AType: Cardinal);
    procedure Rec1(AType, A: Cardinal);
    procedure WRectL(L, Tp, R, B: Integer);
    function LX(const P: TXVPoint): Integer;
    function LY(const P: TXVPoint): Integer;
    procedure SelectStock(H: Cardinal);
    procedure SolidBrush(C: TXVColor);
    procedure FreeBrush;
    procedure MakePen(const St: TXVStroke);
    procedure FreePen;
    procedure WritePath(const P: TXVPath; const M: TXVMatrix);
    procedure ClipTo(const P: TXVPath; Rule: TXVFillRule);
    procedure SetFillMode(Rule: TXVFillRule);
    procedure Polygon(const Pts: array of TXVPoint);
    procedure GradientFill(const P: TXVPath; Rule: TXVFillRule; const Paint: TXVPaint);
    function PatternBrush(const Paint: TXVPaint): Boolean;
    procedure WorldTransform(const M: TXVMatrix);
    procedure EmitPath(const E: TXVElement);
    procedure EmitText(const E: TXVElement; const M: TXVMatrix);
    procedure EmitImage(const E: TXVElement);
    procedure Header(WPx, HPx: Double);
  public
    constructor Create(ADoc: TXVDocument);
    destructor Destroy; override;
    procedure Run(Dest: TStream);
  end;

function Visible(C: TXVColor): Boolean; inline;
begin
  Result := (C shr 24) <> 0;
end;

function ColorRef(C: TXVColor): Cardinal; inline;
begin
  Result := ((C shr 16) and $FF) or (C and $FF00) or ((C and $FF) shl 16);
end;

constructor TEmfOut.Create(ADoc: TXVDocument);
begin
  inherited Create;
  Doc := ADoc;
  S := TMemoryStream.Create;
end;

destructor TEmfOut.Destroy;
begin
  S.Free;
  inherited Destroy;
end;

procedure TEmfOut.W32(V: Cardinal);
begin
  S.WriteBuffer(V, 4);
end;

procedure TEmfOut.WI(V: Integer);
begin
  S.WriteBuffer(V, 4);
end;

procedure TEmfOut.W16(V: Word);
begin
  S.WriteBuffer(V, 2);
end;

procedure TEmfOut.W8(V: Byte);
begin
  S.WriteBuffer(V, 1);
end;

procedure TEmfOut.WF(V: Single);
begin
  S.WriteBuffer(V, 4);
end;

procedure TEmfOut.Pad4;
begin
  while (S.Position - RecStart) mod 4 <> 0 do W8(0);
end;

procedure TEmfOut.BeginRec(AType: Cardinal);
begin
  RecStart := S.Position;
  W32(AType);
  W32(0);
end;

procedure TEmfOut.EndRec;
var
  sz: Cardinal;
  here: Int64;
begin
  Pad4;
  here := S.Position;
  sz := here - RecStart;
  S.Position := RecStart + 4;
  W32(sz);
  S.Position := here;
  Inc(RecCount);
end;

procedure TEmfOut.Rec0(AType: Cardinal);
begin
  BeginRec(AType);
  EndRec;
end;

procedure TEmfOut.Rec1(AType, A: Cardinal);
begin
  BeginRec(AType);
  W32(A);
  EndRec;
end;

procedure TEmfOut.WRectL(L, Tp, R, B: Integer);
begin
  WI(L); WI(Tp); WI(R); WI(B);
end;

function Clip32(V: Double): Integer; inline;
begin
  if V > 2e9 then Result := 2000000000
  else if V < -2e9 then Result := -2000000000
  else Result := Round(V);
end;

function TEmfOut.LX(const P: TXVPoint): Integer;
begin
  Result := Clip32(T.A * P.X + T.C * P.Y + T.E);
end;

function TEmfOut.LY(const P: TXVPoint): Integer;
begin
  Result := Clip32(T.B * P.X + T.D * P.Y + T.F);
end;

procedure TEmfOut.SelectStock(H: Cardinal);
begin
  Rec1(EMR_SELECTOBJECT, H);
end;

procedure TEmfOut.SolidBrush(C: TXVColor);
begin
  BeginRec(EMR_CREATEBRUSHINDIRECT);
  W32(H_BRUSH);
  W32(0);                // BS_SOLID
  W32(ColorRef(C));
  W32(0);
  EndRec;
  Rec1(EMR_SELECTOBJECT, H_BRUSH);
end;

procedure TEmfOut.FreeBrush;
begin
  SelectStock(NULL_BRUSH);
  Rec1(EMR_DELETEOBJECT, H_BRUSH);
end;

procedure TEmfOut.MakePen(const St: TXVStroke);
var
  style: Cardinal;
  w: Double;
  i, n: Integer;
  dashes: array of Cardinal;
begin
  w := St.Width * T.ScaleFactor;
  n := 0;
  dashes := nil;
  if (St.Width <= 0) or (w < 1) then
  begin
    style := $00000000;            // PS_COSMETIC, PS_SOLID
    w := 1;
  end
  else
  begin
    style := $00010000;            // PS_GEOMETRIC
    case St.Cap of
      lcRound: style := style or $0000;
      lcSquare: style := style or $0100;
    else
      style := style or $0200;
    end;
    case St.Join of
      ljRound: style := style or $0000;
      ljBevel: style := style or $1000;
    else
      style := style or $2000;
    end;
    if Length(St.Dashes) >= 2 then
    begin
      n := Length(St.Dashes);
      SetLength(dashes, n);
      for i := 0 to n - 1 do dashes[i] := Max(1, Round(St.Dashes[i] * T.ScaleFactor));
      style := style or 7;           // PS_USERSTYLE
    end;
  end;
  BeginRec(EMR_EXTCREATEPEN);
  W32(H_PEN);
  W32(0); W32(0); W32(0); W32(0);   // no pattern bitmap
  W32(style);
  W32(Max(1, Round(w)));
  W32(0);                            // BS_SOLID
  W32(ColorRef(St.Paint.Color));
  W32(0);                            // hatch
  W32(n);
  for i := 0 to n - 1 do W32(dashes[i]);
  EndRec;
  Rec1(EMR_SELECTOBJECT, H_PEN);
  if (style and $3000) = $2000 then
  begin
    BeginRec(EMR_SETMITERLIMIT);
    W32(Max(1, Round(St.MiterLimit)));
    EndRec;
  end;
end;

procedure TEmfOut.FreePen;
begin
  SelectStock(NULL_PEN);
  Rec1(EMR_DELETEOBJECT, H_PEN);
end;

// BEGINPATH .. ENDPATH of a path (M maps the path points to the document)
procedure TEmfOut.WritePath(const P: TXVPath; const M: TXVMatrix);
var
  i, k, j, n: Integer;
  pts: array of TXVPoint;
  kind: TXVPathCmd;
  minx, miny, maxx, maxy: Integer;

  procedure Flush;
  var q, x, y: Integer;
  begin
    if n = 0 then Exit;
    if kind = pcLineTo then BeginRec(EMR_POLYLINETO) else BeginRec(EMR_POLYBEZIERTO);
    minx := MaxInt; miny := MaxInt; maxx := -MaxInt; maxy := -MaxInt;
    for q := 0 to n - 1 do
    begin
      x := LX(pts[q]); y := LY(pts[q]);
      minx := Min(minx, x); miny := Min(miny, y); maxx := Max(maxx, x); maxy := Max(maxy, y);
    end;
    WRectL(minx, miny, maxx, maxy);
    W32(n);
    for q := 0 to n - 1 do
    begin
      WI(LX(pts[q])); WI(LY(pts[q]));
    end;
    EndRec;
    n := 0;
  end;

  procedure Add(const Pt: TXVPoint);
  begin
    if n >= Length(pts) then SetLength(pts, Max(64, n * 2));
    pts[n] := M.Apply(Pt);
    Inc(n);
  end;

begin
  Rec0(EMR_BEGINPATH);
  k := 0; n := 0;
  pts := nil;
  kind := pcLineTo;
  for i := 0 to P.NCmd - 1 do
    case P.Cmds[i] of
      pcMoveTo:
        begin
          Flush;
          BeginRec(EMR_MOVETOEX);
          WI(LX(M.Apply(P.Pts[k]))); WI(LY(M.Apply(P.Pts[k])));
          EndRec;
          Inc(k);
        end;
      pcLineTo:
        begin
          if (n > 0) and (kind <> pcLineTo) then Flush;
          kind := pcLineTo;
          Add(P.Pts[k]);
          Inc(k);
        end;
      pcCubicTo:
        begin
          if (n > 0) and (kind <> pcCubicTo) then Flush;
          kind := pcCubicTo;
          for j := 0 to 2 do Add(P.Pts[k + j]);
          Inc(k, 3);
        end;
      pcClose:
        begin
          Flush;
          Rec0(EMR_CLOSEFIGURE);
        end;
    end;
  Flush;
  Rec0(EMR_ENDPATH);
end;

procedure TEmfOut.SetFillMode(Rule: TXVFillRule);
begin
  if Rule = frEvenOdd then Rec1(EMR_SETPOLYFILLMODE, 1) else Rec1(EMR_SETPOLYFILLMODE, 2);
end;

procedure TEmfOut.ClipTo(const P: TXVPath; Rule: TXVFillRule);
begin
  SetFillMode(Rule);
  WritePath(P, TXVMatrix.Identity);
  Rec1(EMR_SELECTCLIPPATH, 1);        // RGN_AND
end;

procedure TEmfOut.Polygon(const Pts: array of TXVPoint);
var
  i, x, y, minx, miny, maxx, maxy: Integer;
begin
  BeginRec(EMR_POLYGON);
  minx := MaxInt; miny := MaxInt; maxx := -MaxInt; maxy := -MaxInt;
  for i := 0 to High(Pts) do
  begin
    x := LX(Pts[i]); y := LY(Pts[i]);
    minx := Min(minx, x); miny := Min(miny, y); maxx := Max(maxx, x); maxy := Max(maxy, y);
  end;
  WRectL(minx, miny, maxx, maxy);
  W32(Length(Pts));
  for i := 0 to High(Pts) do
  begin
    WI(LX(Pts[i])); WI(LY(Pts[i]));
  end;
  EndRec;
end;

function StopColor(const G: TXVGradient; t: Double): TXVColor;
var i: Integer; u: Double;
begin
  case G.Spread of
    spRepeat: t := t - Floor(t);
    spReflect:
      begin
        t := Abs(t);
        t := t - 2 * Floor(t / 2);
        if t > 1 then t := 2 - t;
      end;
  end;
  if t <= G.Stops[0].Offset then Exit(G.Stops[0].Color);
  for i := 0 to High(G.Stops) - 1 do
    if t <= G.Stops[i + 1].Offset then
    begin
      if G.Stops[i + 1].Offset - G.Stops[i].Offset > 1e-9 then
        u := (t - G.Stops[i].Offset) / (G.Stops[i + 1].Offset - G.Stops[i].Offset)
      else u := 1;
      Exit(XVLerpColor(G.Stops[i].Color, G.Stops[i + 1].Color, u));
    end;
  Result := G.Stops[High(G.Stops)].Color;
end;

// gradient as colour bands clipped to the shape
procedure TEmfOut.GradientFill(const P: TXVPath; Rule: TXVFillRule; const Paint: TXVPaint);
const
  BANDS = 96;
var
  G: TXVGradient;
  b: TXVRect;
  inv: TXVMatrix;
  c: array[0..3] of TXVPoint;
  i, k: Integer;
  dx, dy, len, nx, ny, t, t0, t1, tmin, tmax, smin, smax, s, r, fx, fy: Double;
  q: array[0..3] of TXVPoint;
  circ: array of TXVPoint;
  col: TXVColor;
begin
  G := Doc.Gradients[Paint.Index];
  if (Length(G.Stops) = 0) or not P.Bounds(b) then Exit;
  Rec0(EMR_SAVEDC);
  ClipTo(P, Rule);
  SelectStock(NULL_PEN);
  inv := G.Matrix.Invert;
  c[0] := inv.Apply(b.Left, b.Top); c[1] := inv.Apply(b.Right, b.Top);
  c[2] := inv.Apply(b.Right, b.Bottom); c[3] := inv.Apply(b.Left, b.Bottom);
  if G.Kind = gkLinear then
  begin
    dx := G.X2 - G.X1; dy := G.Y2 - G.Y1;
    len := Hypot(dx, dy);
    if len < 1e-12 then begin dx := 1; dy := 0; len := 1; end;
    nx := -dy / len; ny := dx / len;
    tmin := 1e300; tmax := -1e300; smin := 1e300; smax := -1e300;
    for i := 0 to 3 do
    begin
      t := ((c[i].X - G.X1) * dx + (c[i].Y - G.Y1) * dy) / (len * len);
      s := (c[i].X - G.X1) * nx + (c[i].Y - G.Y1) * ny;
      tmin := Min(tmin, t); tmax := Max(tmax, t);
      smin := Min(smin, s); smax := Max(smax, s);
    end;
    smin := smin - 1; smax := smax + 1;
    for k := 0 to BANDS - 1 do
    begin
      t0 := tmin + (tmax - tmin) * k / BANDS;
      t1 := tmin + (tmax - tmin) * (k + 1) / BANDS + (tmax - tmin) / BANDS * 0.3;
      col := StopColor(G, (t0 + t1) / 2);
      q[0] := G.Matrix.Apply(G.X1 + t0 * dx + smin * nx, G.Y1 + t0 * dy + smin * ny);
      q[1] := G.Matrix.Apply(G.X1 + t1 * dx + smin * nx, G.Y1 + t1 * dy + smin * ny);
      q[2] := G.Matrix.Apply(G.X1 + t1 * dx + smax * nx, G.Y1 + t1 * dy + smax * ny);
      q[3] := G.Matrix.Apply(G.X1 + t0 * dx + smax * nx, G.Y1 + t0 * dy + smax * ny);
      SolidBrush(col);
      Polygon(q);
      FreeBrush;
    end;
  end
  else
  begin
    // outside colour first, then rings from the outside in
    SolidBrush(StopColor(G, 1));
    q[0] := XVPt(b.Left - 1, b.Top - 1); q[1] := XVPt(b.Right + 1, b.Top - 1);
    q[2] := XVPt(b.Right + 1, b.Bottom + 1); q[3] := XVPt(b.Left - 1, b.Bottom + 1);
    Polygon(q);
    FreeBrush;
    SetLength(circ, 72);
    for k := 0 to BANDS - 1 do
    begin
      t := 1 - k / BANDS;
      r := G.R * t;
      fx := G.FX + (G.CX - G.FX) * t;
      fy := G.FY + (G.CY - G.FY) * t;
      for i := 0 to High(circ) do
        circ[i] := G.Matrix.Apply(fx + r * Cos(2 * Pi * i / Length(circ)), fy + r * Sin(2 * Pi * i / Length(circ)));
      SolidBrush(StopColor(G, t - 0.5 / BANDS));
      Polygon(circ);
      FreeBrush;
    end;
  end;
  Rec1(EMR_RESTOREDC, Cardinal(-1));
end;

// a DIB pattern brush of the tile scaled to the output size
function TEmfOut.PatternBrush(const Paint: TXVPaint): Boolean;
var
  pt: TXVPattern;
  src: TXVImage;
  tw, th, x, y, sx, sy: Integer;
  sc: Double;
  bits: array of Cardinal;
begin
  Result := False;
  if (Paint.Index < 0) or (Paint.Index > High(Doc.Patterns)) then Exit;
  pt := Doc.Patterns[Paint.Index];
  if (pt.Image < 0) or (pt.Image > High(Doc.Images)) then Exit;
  src := Doc.Images[pt.Image];
  if (src.W <= 0) or (src.H <= 0) then Exit;
  if pt.DeviceTile then sc := SUB else sc := pt.Matrix.ScaleFactor * T.ScaleFactor;
  tw := EnsureRange(Round(src.W * sc), 1, 1024);
  th := EnsureRange(Round(src.H * sc), 1, 1024);
  SetLength(bits, tw * th);
  for y := 0 to th - 1 do
    for x := 0 to tw - 1 do
    begin
      sx := Min(src.W - 1, x * src.W div tw);
      sy := Min(src.H - 1, y * src.H div th);
      // rows bottom-up, transparent pixels white
      if (src.Px[sy * src.W + sx] shr 24) < 128 then bits[(th - 1 - y) * tw + x] := $FFFFFF
      else bits[(th - 1 - y) * tw + x] := src.Px[sy * src.W + sx] and $FFFFFF;
    end;
  BeginRec(EMR_CREATEDIBPATTERNBRUSHPT);
  W32(H_BRUSH);
  W32(0);                            // DIB_RGB_COLORS
  W32(32); W32(40);                  // offBmi, cbBmi
  W32(72); W32(tw * th * 4);         // offBits, cbBits
  // BITMAPINFOHEADER
  W32(40); WI(tw); WI(th); W16(1); W16(32); W32(0); W32(tw * th * 4); WI(3780); WI(3780); W32(0); W32(0);
  S.WriteBuffer(bits[0], tw * th * 4);
  EndRec;
  Rec1(EMR_SELECTOBJECT, H_BRUSH);
  Result := True;
end;

procedure TEmfOut.WorldTransform(const M: TXVMatrix);
begin
  BeginRec(EMR_SETWORLDTRANSFORM);
  WF(M.A); WF(M.B); WF(M.C); WF(M.D); WF(M.E); WF(M.F);
  EndRec;
end;

procedure TEmfOut.EmitPath(const E: TXVElement);
var
  hasFill, hasStroke, gradFill: Boolean;
  fc: TXVColor;
begin
  if E.Path.NCmd = 0 then Exit;
  hasFill := (E.Fill.Kind <> pkNone) and Visible(E.Fill.Color) and (E.Opacity > 0.002);
  hasStroke := (E.Stroke.Paint.Kind <> pkNone) and Visible(E.Stroke.Paint.Color) and (E.Opacity > 0.002);
  if not (hasFill or hasStroke) then Exit;
  gradFill := hasFill and (E.Fill.Kind = pkGradient) and (E.Fill.Index >= 0) and (E.Fill.Index <= High(Doc.Gradients));
  if gradFill then
  begin
    GradientFill(E.Path, E.FillRule, E.Fill);
    hasFill := False;
  end;
  if not (hasFill or hasStroke) then Exit;
  SetFillMode(E.FillRule);
  if hasFill then
  begin
    fc := E.Fill.Color;
    if not ((E.Fill.Kind = pkPattern) and PatternBrush(E.Fill)) then SolidBrush(fc);
  end
  else SelectStock(NULL_BRUSH);
  if hasStroke then MakePen(E.Stroke) else SelectStock(NULL_PEN);
  WritePath(E.Path, TXVMatrix.Identity);
  BeginRec(IfThen(hasFill and hasStroke, EMR_STROKEANDFILLPATH, IfThen(hasFill, EMR_FILLPATH, EMR_STROKEPATH)));
  WRectL(BoundsL, BoundsT, BoundsR, BoundsB);
  EndRec;
  if hasFill then FreeBrush;
  if hasStroke then FreePen;
end;

procedure TEmfOut.EmitText(const E: TXVElement; const M: TXVMatrix);
const
  EM = 1000;
var
  ws: UnicodeString;
  face: UnicodeString;
  i, n, x0, y0: Integer;
  k: Double;
  wm: TXVMatrix;
  align: Cardinal;
  dx: array of Integer;
  ch: TStringArray;
  col: TXVColor;
  posK, nextK: Double;
begin
  if (E.Text = '') or (E.Font.Size <= 0) then Exit;
  if E.Fill.Kind <> pkNone then col := E.Fill.Color
  else if E.Stroke.Paint.Kind <> pkNone then col := E.Stroke.Paint.Color
  else Exit;
  if not Visible(col) then Exit;
  k := E.Font.Size / EM;               // text units per EMF text unit
  Rec0(EMR_SAVEDC);
  wm := XVMul(T, XVMul(M, TXVMatrix.Scale(k, k)));
  WorldTransform(wm);
  // font
  BeginRec(EMR_EXTCREATEFONTINDIRECTW);
  W32(H_FONT);
  WI(-EM);                             // lfHeight: em size
  WI(0); WI(0); WI(0);
  WI(EnsureRange(E.Font.Weight, 100, 900));
  W8(Ord(E.Font.Italic)); W8(Ord(E.Font.Underline)); W8(Ord(E.Font.Strike));
  W8(1);                               // DEFAULT_CHARSET
  W8(4);                               // OUT_TT_PRECIS
  W8(0); W8(4); W8(0);                 // clip precision, ANTIALIASED_QUALITY, pitch
  face := UTF8Decode(E.Font.Family);
  if Length(face) > 31 then SetLength(face, 31);
  for i := 0 to 31 do
    if i < Length(face) then W16(Ord(face[i + 1])) else W16(0);
  EndRec;
  Rec1(EMR_SELECTOBJECT, H_FONT);
  Rec1(EMR_SETBKMODE, 1);              // TRANSPARENT
  Rec1(EMR_SETTEXTCOLOR, ColorRef(col));
  case E.Anchor of
    taMiddle: align := 6;
    taEnd: align := 2;
  else
    align := 0;
  end;
  y0 := 0;
  case E.Baseline of
    tbTop: align := align or 0;
    tbBottom: align := align or 8;
    tbMiddle: begin align := align or 24; y0 := Round(0.35 * EM); end;
  else
    align := align or 24;              // TA_BASELINE
  end;
  // the chunk anchor is already resolved by the layout
  if E.Continued or (Length(E.CharX) > 0) then align := align and not 6;
  Rec1(EMR_SETTEXTALIGN, align);
  ws := UTF8Decode(E.Text);
  n := Length(ws);
  dx := nil;
  if Length(E.CharX) > 0 then
  begin
    // advances from the character positions (one entry per UTF-16 unit)
    ch := XVUtf8Chars(E.Text);
    SetLength(dx, n);
    FillChar(dx[0], n * SizeOf(Integer), 0);
    i := 0;
    for x0 := 0 to High(ch) do
    begin
      if x0 <= High(E.CharX) then posK := E.CharX[x0] else posK := E.CharX[High(E.CharX)];
      if x0 + 1 <= High(E.CharX) then nextK := E.CharX[x0 + 1]
      else nextK := posK + XVEstimateTextWidth(E.Font, ch[x0]);
      if i < n then dx[i] := Round((nextK - posK) / k);
      Inc(i, Length(UTF8Decode(ch[x0])));
    end;
  end;
  x0 := 0;
  if Length(E.CharX) > 0 then x0 := Round(E.CharX[0] / k);
  BeginRec(EMR_EXTTEXTOUTW);
  WRectL(BoundsL, BoundsT, BoundsR, BoundsB);
  W32(2);                              // GM_ADVANCED
  WF(0); WF(0);
  WI(x0); WI(y0);                      // reference point
  W32(n);
  W32(76);                             // offString
  W32(0);                              // options
  WRectL(0, 0, -1, -1);
  if dx <> nil then W32(76 + ((n * 2 + 3) div 4) * 4) else W32(0);
  for i := 1 to n do W16(Ord(ws[i]));
  Pad4;
  for i := 0 to High(dx) do WI(dx[i]);
  EndRec;
  SelectStock(DEFAULT_FONT);
  Rec1(EMR_DELETEOBJECT, H_FONT);
  Rec1(EMR_RESTOREDC, Cardinal(-1));
end;

procedure TEmfOut.EmitImage(const E: TXVElement);
var
  img: TXVImage;
  x, y: Integer;
  hasAlpha: Boolean;
  c, a: Cardinal;
  bits: array of Cardinal;
  op: Byte;
begin
  if (E.Image < 0) or (E.Image > High(Doc.Images)) then Exit;
  img := Doc.Images[E.Image];
  if (img.W <= 0) or (img.H <= 0) then Exit;
  hasAlpha := E.Opacity < 0.999;
  for x := 0 to High(img.Px) do
    if (img.Px[x] shr 24) < 255 then begin hasAlpha := True; Break; end;
  SetLength(bits, img.W * img.H);
  for y := 0 to img.H - 1 do
    for x := 0 to img.W - 1 do
    begin
      c := img.Px[y * img.W + x];
      if hasAlpha then
      begin
        a := c shr 24;
        c := (a shl 24) or ((((c shr 16) and $FF) * a div 255) shl 16) or ((((c shr 8) and $FF) * a div 255) shl 8) or
          ((c and $FF) * a div 255);
      end;
      bits[(img.H - 1 - y) * img.W + x] := c;
    end;
  Rec0(EMR_SAVEDC);
  WorldTransform(XVMul(T, E.Matrix));
  if hasAlpha then
  begin
    op := EnsureRange(Round(E.Opacity * 255), 0, 255);
    BeginRec(EMR_ALPHABLEND);
    WRectL(BoundsL, BoundsT, BoundsR, BoundsB);
    WI(0); WI(0); WI(img.W); WI(img.H);              // destination
    W8(0); W8(0); W8(op); W8(1);                     // AC_SRC_OVER, constant alpha, AC_SRC_ALPHA
    WI(0); WI(0);                                    // source origin
    WF(1); WF(0); WF(0); WF(1); WF(0); WF(0);        // source transform
    W32(0);                                          // background
    W32(0);                                          // DIB_RGB_COLORS
    W32(108); W32(40);                               // offBmi, cbBmi
    W32(148); W32(img.W * img.H * 4);                // offBits, cbBits
    WI(img.W); WI(img.H);                            // source size
    W32(40); WI(img.W); WI(img.H); W16(1); W16(32); W32(0); W32(img.W * img.H * 4); WI(3780); WI(3780); W32(0); W32(0);
    S.WriteBuffer(bits[0], img.W * img.H * 4);
    EndRec;
  end
  else
  begin
    Rec1(EMR_SETSTRETCHBLTMODE, 4);                  // HALFTONE
    BeginRec(EMR_STRETCHDIBITS);
    WRectL(BoundsL, BoundsT, BoundsR, BoundsB);
    WI(0); WI(0);                                    // destination origin
    WI(0); WI(0); WI(img.W); WI(img.H);              // source rectangle
    W32(80); W32(40);                                // offBmi, cbBmi
    W32(120); W32(img.W * img.H * 4);                // offBits, cbBits
    W32(0);                                          // DIB_RGB_COLORS
    W32($00CC0020);                                  // SRCCOPY
    WI(img.W); WI(img.H);                            // destination size
    W32(40); WI(img.W); WI(img.H); W16(1); W16(32); W32(0); W32(img.W * img.H * 4); WI(3780); WI(3780); W32(0); W32(0);
    S.WriteBuffer(bits[0], img.W * img.H * 4);
    EndRec;
  end;
  Rec1(EMR_RESTOREDC, Cardinal(-1));
end;

procedure TEmfOut.Header(WPx, HPx: Double);
const
  DEV_MM_X = 320;
  DEV_MM_Y = 240;
var
  desc: UnicodeString;
  i: Integer;
begin
  desc := 'XelVectors'#0 + UTF8Decode(Doc.Title) + #0#0;
  BeginRec(EMR_HEADER);
  WRectL(BoundsL, BoundsT, BoundsR, BoundsB);
  // frame in 0.01 mm
  WRectL(0, 0, Round(WPx * 2540 / 96), Round(HPx * 2540 / 96));
  W32($464D4520);                      // " EMF"
  W32($00010000);
  W32(0);                              // file size, patched later
  W32(0);                              // record count, patched later
  W16(4);                              // handles (0 reserved + brush, pen, font)
  W16(0);
  W32(Length(desc));
  W32(108);                            // description offset
  W32(0);                              // palette entries
  // reference device: 1536 dpi
  WI(Round(DEV_MM_X / 25.4 * 96 * SUB)); WI(Round(DEV_MM_Y / 25.4 * 96 * SUB));
  WI(DEV_MM_X); WI(DEV_MM_Y);
  W32(0); W32(0); W32(0);              // no pixel format, no OpenGL
  WI(DEV_MM_X * 1000); WI(DEV_MM_Y * 1000);
  for i := 1 to Length(desc) do W16(Ord(desc[i]));
  EndRec;
end;

procedure TEmfOut.Run(Dest: TStream);
var
  vb: TXVRect;
  wpx, hpx: Double;
  i, j: Integer;
  e: TXVElement;
  layout: array of TXVMatrix;
  pen, a, adv, tot, shift: TXVPoint;
  m: TXVMatrix;
  run: array of Integer;
  w: Double;
  sz, cnt: Cardinal;
begin
  vb := Doc.ViewBox;
  if vb.IsEmpty then vb := XVRect(0, 0, Max(Doc.Width, 1), Max(Doc.Height, 1));
  wpx := Doc.Width; hpx := Doc.Height;
  if wpx <= 0 then wpx := vb.Width;
  if hpx <= 0 then hpx := vb.Height;
  T := TXVMatrix.Make(SUB * wpx / vb.Width, 0, 0, SUB * hpx / vb.Height, -vb.Left * SUB * wpx / vb.Width,
    -vb.Top * SUB * hpx / vb.Height);
  BoundsL := 0; BoundsT := 0;
  BoundsR := Round(wpx * SUB) - 1; BoundsB := Round(hpx * SUB) - 1;
  Header(wpx, hpx);
  Rec1(EMR_SETBKMODE, 1);
  if Visible(Doc.Background) then
  begin
    SelectStock(NULL_PEN);
    SolidBrush(Doc.Background);
    Polygon([XVPt(vb.Left, vb.Top), XVPt(vb.Right, vb.Top), XVPt(vb.Right, vb.Bottom), XVPt(vb.Left, vb.Bottom)]);
    FreeBrush;
  end;
  // text layout with estimated widths (EMF players measure on their own,
  // only chunks of several runs and anchors of such chunks need this)
  SetLength(layout, Doc.Count);
  i := 0;
  while i < Doc.Count do
  begin
    layout[i] := Doc.Elements[i].Matrix;
    if (Doc.Elements[i].Kind = ekText) and not Doc.Elements[i].Continued and (i + 1 < Doc.Count) and
       (Doc.Elements[i + 1].Kind = ekText) and Doc.Elements[i + 1].Continued then
    begin
      run := nil;
      j := i;
      while (j < Doc.Count) and (Doc.Elements[j].Kind = ekText) and ((j = i) or Doc.Elements[j].Continued) do
      begin
        SetLength(run, Length(run) + 1);
        run[High(run)] := j;
        Inc(j);
      end;
      tot := XVPt(0, 0);
      for j := 0 to High(run) do
      begin
        w := XVEstimateTextWidth(Doc.Elements[run[j]].Font, Doc.Elements[run[j]].Text);
        adv := Doc.Elements[run[j]].Matrix.ApplyVec(w, 0);
        tot.X := tot.X + adv.X; tot.Y := tot.Y + adv.Y;
      end;
      case Doc.Elements[i].Anchor of
        taMiddle: shift := XVPt(-tot.X / 2, -tot.Y / 2);
        taEnd: shift := XVPt(-tot.X, -tot.Y);
      else
        shift := XVPt(0, 0);
      end;
      pen := XVPt(Doc.Elements[i].Matrix.E + shift.X, Doc.Elements[i].Matrix.F + shift.Y);
      for j := 0 to High(run) do
      begin
        m := Doc.Elements[run[j]].Matrix;
        if j = 0 then a := XVPt(0, 0) else a := XVPt(m.E, m.F);
        m.E := pen.X + a.X; m.F := pen.Y + a.Y;
        layout[run[j]] := m;
        w := XVEstimateTextWidth(Doc.Elements[run[j]].Font, Doc.Elements[run[j]].Text);
        adv := m.ApplyVec(w, 0);
        pen := XVPt(m.E + adv.X, m.F + adv.Y);
      end;
      i := run[High(run)];
    end;
    Inc(i);
  end;
  for i := 0 to Doc.Count - 1 do
  begin
    e := Doc.Elements[i];
    case e.Kind of
      ekGroup:
        begin
          Rec0(EMR_SAVEDC);
          if (e.Clip >= 0) and (e.Clip <= High(Doc.Clips)) then ClipTo(Doc.Clips[e.Clip].Path, Doc.Clips[e.Clip].Rule);
        end;
      ekGroupEnd: Rec1(EMR_RESTOREDC, Cardinal(-1));
      ekPath: EmitPath(e);
      ekText: EmitText(e, layout[i]);    // continued runs at their estimated position
      ekImage: EmitImage(e);
    end;
  end;
  // EMR_EOF: no palette entries, their offset, the size of this record
  BeginRec(EMR_EOF);
  W32(0); W32(16); W32(20);
  EndRec;
  sz := S.Size;
  cnt := RecCount;
  S.Position := 48;
  W32(sz);
  W32(cnt);
  S.Position := 0;
  Dest.CopyFrom(S, S.Size);
end;

procedure XVWriteEMFDoc(Doc: TXVDocument; Stream: TStream);
var W: TEmfOut;
begin
  W := TEmfOut.Create(Doc);
  try
    W.Run(Stream);
  finally
    W.Free;
  end;
end;

initialization
  XVRegisterWriter('EMF', 'emf', XVWriteEMFDoc);
end.
