unit XVReadXAML;

{$mode delphi}{$H+}
{$R-}{$Q-}

// XelVectors - XAML reader (WPF / Silverlight / XPS fixed pages, the vector
// subset): Canvas, Grid, StackPanel and Viewbox containers, Path (Data in the
// path mini-language or as geometry elements: PathGeometry, EllipseGeometry,
// RectangleGeometry, LineGeometry, GeometryGroup, CombinedGeometry), Rectangle,
// Ellipse, Line, Polyline, Polygon, Border, TextBlock (with Runs), Glyphs,
// DrawingImage / DrawingGroup / GeometryDrawing, solid and gradient brushes,
// pens, transforms, opacity, clip geometry and StaticResource references.

interface

uses
  SysUtils, Classes, Math, DOM, XMLRead, XVModel, XVReadSVG;

function XVIsXAML(const Data: TBytes): Boolean;
procedure XVReadXAMLDoc(Doc: TXVDocument; const Data: TBytes);

implementation

type
  TXState = record
    M: TXVMatrix;
    Opacity: Double;
  end;

  TXBrushSpec = record
    Node: TDOMElement;             // brush element, nil when given as text
    Text: string;
  end;

  { TXamlReader }

  TXamlReader = class
    Doc: TXVDocument;
    XDoc: TXMLDocument;
    Res: TStringList;              // x:Key -> element
    function LName(N: TDOMNode): string;
    function Attr(N: TDOMNode; const Name: string): string;
    function HasA(N: TDOMNode; const Name: string): Boolean;
    function PropElem(E: TDOMElement; const Prop: string): TDOMElement;
    function PropValue(E: TDOMElement; const Prop: string; out Sub: TDOMElement): string;
    procedure CollectRes(N: TDOMNode);
    function Resolve(const V: string): TDOMElement;
    function ParseColor(const S: string; out C: TXVColor): Boolean;
    function ParseMatrixText(const S: string): TXVMatrix;
    function TransformOf(T: TDOMElement): TXVMatrix;
    function ElemTransform(E: TDOMElement; W, H: Double): TXVMatrix;
    function MakePaint(E: TDOMElement; const Prop: string; Opacity: Double; const Box: TXVRect;
      const M: TXVMatrix): TXVPaint;
    function BrushPaint(B: TDOMElement; const Txt: string; Opacity: Double; const Box: TXVRect;
      const M: TXVMatrix): TXVPaint;
    function GeometryOf(G: TDOMElement; const Txt: string; out P: TXVPath; out Rule: TXVFillRule): Boolean;
    function ShapeStroke(E: TDOMElement; Opacity: Double; const Box: TXVRect; const M: TXVMatrix): TXVStroke;
    function PenStroke(Pen: TDOMElement; Opacity: Double; const Box: TXVRect; const M: TXVMatrix): TXVStroke;
    procedure EmitShape(E: TDOMElement; const P: TXVPath; Rule: TXVFillRule; const St: TXState);
    procedure EmitText(E: TDOMElement; const St: TXState);
    procedure EmitGlyphs(E: TDOMElement; const St: TXState);
    procedure Drawing(E: TDOMElement; const St: TXState);
    procedure Node(E: TDOMElement; const St: TXState);
    procedure Run(const Data: TBytes);
  end;

function Num(const S: string; Def: Double = 0): Double;
begin
  Result := XVStrToFloat(Trim(S), Def);
end;

function SplitNums(const S: string): TXVDoubles;
var
  i, n: Integer;
  t: string;
begin
  Result := nil;
  n := 0;
  t := '';
  for i := 1 to Length(S) + 1 do
    if (i > Length(S)) or (S[i] in [',', ' ', #9, #10, #13]) then
    begin
      if t <> '' then
      begin
        SetLength(Result, n + 1);
        Result[n] := XVStrToFloat(t, 0);
        Inc(n);
        t := '';
      end;
    end
    else t := t + S[i];
end;

function TXamlReader.LName(N: TDOMNode): string;
var s: string; p: Integer;
begin
  s := UTF8Encode(N.NodeName);
  p := Pos(':', s);
  if p > 0 then Delete(s, 1, p);
  Result := s;
end;

function TXamlReader.Attr(N: TDOMNode; const Name: string): string;
var a: TDOMNode; i: Integer; nm: string;
begin
  Result := '';
  if (N = nil) or (N.Attributes = nil) then Exit;
  a := N.Attributes.GetNamedItem(UTF8Decode(Name));
  if a <> nil then Exit(UTF8Encode(a.NodeValue));
  // prefixed attributes (x:Key, Canvas.Left written as p:Canvas.Left)
  for i := 0 to N.Attributes.Length - 1 do
  begin
    nm := UTF8Encode(N.Attributes.Item[i].NodeName);
    if (Pos(':', nm) > 0) and SameText(Copy(nm, Pos(':', nm) + 1, MaxInt), Name) then
      Exit(UTF8Encode(N.Attributes.Item[i].NodeValue));
  end;
end;

function TXamlReader.HasA(N: TDOMNode; const Name: string): Boolean;
begin
  Result := Attr(N, Name) <> '';
end;

// the property element <Owner.Prop> of E, its first element child
function TXamlReader.PropElem(E: TDOMElement; const Prop: string): TDOMElement;
var c, g: TDOMNode; n: string;
begin
  Result := nil;
  c := E.FirstChild;
  while c <> nil do
  begin
    if c is TDOMElement then
    begin
      n := LName(c);
      if (Pos('.', n) > 0) and SameText(Copy(n, Pos('.', n) + 1, MaxInt), Prop) then
      begin
        g := c.FirstChild;
        while (g <> nil) and not (g is TDOMElement) do g := g.NextSibling;
        Exit(TDOMElement(g));
      end;
    end;
    c := c.NextSibling;
  end;
end;

// the property as an attribute (Text) or element (Sub), resources resolved
function TXamlReader.PropValue(E: TDOMElement; const Prop: string; out Sub: TDOMElement): string;
begin
  Sub := PropElem(E, Prop);
  Result := Attr(E, Prop);
  if (Sub = nil) and (Pos('{', Result) = 1) then
  begin
    Sub := Resolve(Result);
    if Sub <> nil then Result := '';
  end;
end;

procedure TXamlReader.CollectRes(N: TDOMNode);
var c: TDOMNode; k: string;
begin
  if N is TDOMElement then
  begin
    k := Attr(N, 'Key');
    if k = '' then k := Attr(N, 'Name');
    if k <> '' then Res.AddObject(k, N);
  end;
  c := N.FirstChild;
  while c <> nil do
  begin
    CollectRes(c);
    c := c.NextSibling;
  end;
end;

// "{StaticResource key}" / "{DynamicResource key}"
function TXamlReader.Resolve(const V: string): TDOMElement;
var s: string; p, i: Integer;
begin
  Result := nil;
  s := Trim(V);
  if (s = '') or (s[1] <> '{') then Exit;
  s := Trim(Copy(s, 2, Length(s) - 2));
  p := Pos(' ', s);
  if p = 0 then Exit;
  s := Trim(Copy(s, p + 1, MaxInt));
  i := Res.IndexOf(s);
  if i >= 0 then Result := TDOMElement(Res.Objects[i]);
end;

function TXamlReader.ParseColor(const S: string; out C: TXVColor): Boolean;
var
  t: string;
  v: TXVDoubles;

  function H(i: Integer): Integer;
  begin
    Result := StrToIntDef('$' + Copy(t, i, 2), 0);
  end;

begin
  Result := False;
  C := XV_BLACK;
  t := Trim(S);
  if t = '' then Exit;
  if t[1] = '#' then
  begin
    case Length(t) of
      9: C := XVRGBA(H(4), H(6), H(8), H(2));
      7: C := XVRGB(H(2), H(4), H(6));
      5: C := XVRGBA(StrToIntDef('$' + t[3], 0) * 17, StrToIntDef('$' + t[4], 0) * 17, StrToIntDef('$' + t[5], 0) * 17,
        StrToIntDef('$' + t[2], 0) * 17);
      4: C := XVRGB(StrToIntDef('$' + t[2], 0) * 17, StrToIntDef('$' + t[3], 0) * 17, StrToIntDef('$' + t[4], 0) * 17);
    else
      Exit;
    end;
    Exit(True);
  end;
  if LowerCase(Copy(t, 1, 3)) = 'sc#' then
  begin
    // scRGB floats: [a,] r, g, b (linear light)
    v := SplitNums(Copy(t, 4, MaxInt));
    if Length(v) = 4 then C := XVRGBA(Round(255 * Power(EnsureRange(v[1], 0, 1), 1 / 2.2)),
      Round(255 * Power(EnsureRange(v[2], 0, 1), 1 / 2.2)), Round(255 * Power(EnsureRange(v[3], 0, 1), 1 / 2.2)),
      Round(255 * EnsureRange(v[0], 0, 1)))
    else if Length(v) = 3 then C := XVRGB(Round(255 * Power(EnsureRange(v[0], 0, 1), 1 / 2.2)),
      Round(255 * Power(EnsureRange(v[1], 0, 1), 1 / 2.2)), Round(255 * Power(EnsureRange(v[2], 0, 1), 1 / 2.2)))
    else Exit;
    Exit(True);
  end;
  if SameText(t, 'Transparent') then begin C := 0; Exit(True); end;
  Result := XVParseCssColor(t, C, XV_BLACK);
end;

function TXamlReader.ParseMatrixText(const S: string): TXVMatrix;
var v: TXVDoubles;
begin
  Result := TXVMatrix.Identity;
  if SameText(Trim(S), 'Identity') then Exit;
  v := SplitNums(S);
  if Length(v) >= 6 then Result := TXVMatrix.Make(v[0], v[1], v[2], v[3], v[4], v[5]);
end;

function TXamlReader.TransformOf(T: TDOMElement): TXVMatrix;
var
  n: string;
  c: TDOMNode;
  cx, cy, a: Double;
  sub: TDOMElement;
begin
  Result := TXVMatrix.Identity;
  if T = nil then Exit;
  n := LName(T);
  if n = 'MatrixTransform' then
  begin
    if HasA(T, 'Matrix') then Result := ParseMatrixText(Attr(T, 'Matrix'))
    else
    begin
      sub := PropElem(T, 'Matrix');
      if sub <> nil then
        Result := TXVMatrix.Make(Num(Attr(sub, 'M11'), 1), Num(Attr(sub, 'M12')), Num(Attr(sub, 'M21')),
          Num(Attr(sub, 'M22'), 1), Num(Attr(sub, 'OffsetX')), Num(Attr(sub, 'OffsetY')));
    end;
  end
  else if n = 'TranslateTransform' then Result := TXVMatrix.Translate(Num(Attr(T, 'X')), Num(Attr(T, 'Y')))
  else if n = 'ScaleTransform' then
  begin
    cx := Num(Attr(T, 'CenterX')); cy := Num(Attr(T, 'CenterY'));
    Result := XVMul(TXVMatrix.Translate(cx, cy), XVMul(TXVMatrix.Scale(Num(Attr(T, 'ScaleX'), 1),
      Num(Attr(T, 'ScaleY'), 1)), TXVMatrix.Translate(-cx, -cy)));
  end
  else if n = 'RotateTransform' then
  begin
    cx := Num(Attr(T, 'CenterX')); cy := Num(Attr(T, 'CenterY'));
    a := DegToRad(Num(Attr(T, 'Angle')));
    Result := XVMul(TXVMatrix.Translate(cx, cy), XVMul(TXVMatrix.Rotate(a), TXVMatrix.Translate(-cx, -cy)));
  end
  else if n = 'SkewTransform' then
  begin
    cx := Num(Attr(T, 'CenterX')); cy := Num(Attr(T, 'CenterY'));
    Result := XVMul(TXVMatrix.Translate(cx, cy), XVMul(XVMul(TXVMatrix.SkewX(DegToRad(Num(Attr(T, 'AngleX')))),
      TXVMatrix.SkewY(DegToRad(Num(Attr(T, 'AngleY'))))), TXVMatrix.Translate(-cx, -cy)));
  end
  else if (n = 'TransformGroup') or (n = 'CompositeTransform') then
  begin
    if n = 'CompositeTransform' then
    begin
      // Silverlight: scale, skew, rotate, translate around the centre
      cx := Num(Attr(T, 'CenterX')); cy := Num(Attr(T, 'CenterY'));
      Result := XVMul(TXVMatrix.Translate(-cx, -cy), TXVMatrix.Identity);
      Result := XVMul(TXVMatrix.Scale(Num(Attr(T, 'ScaleX'), 1), Num(Attr(T, 'ScaleY'), 1)), Result);
      Result := XVMul(XVMul(TXVMatrix.SkewX(DegToRad(Num(Attr(T, 'SkewX')))), TXVMatrix.SkewY(DegToRad(Num(Attr(T, 'SkewY'))))), Result);
      Result := XVMul(TXVMatrix.Rotate(DegToRad(Num(Attr(T, 'Rotation')))), Result);
      Result := XVMul(TXVMatrix.Translate(cx + Num(Attr(T, 'TranslateX')), cy + Num(Attr(T, 'TranslateY'))), Result);
      Exit;
    end;
    // children are applied in order: the later ones after the earlier
    c := T.FirstChild;
    while c <> nil do
    begin
      if c is TDOMElement then
      begin
        if Pos('.', LName(c)) > 0 then
        begin
          // <TransformGroup.Children>
          sub := TDOMElement(c.FirstChild);
          while sub <> nil do
          begin
            if sub is TDOMElement then Result := XVMul(TransformOf(sub), Result);
            sub := TDOMElement(sub.NextSibling);
          end;
        end
        else Result := XVMul(TransformOf(TDOMElement(c)), Result);
      end;
      c := c.NextSibling;
    end;
  end;
end;

// Canvas offset, then the render transform around its origin
function TXamlReader.ElemTransform(E: TDOMElement; W, H: Double): TXVMatrix;
var
  sub: TDOMElement;
  txt: string;
  rt: TXVMatrix;
  org: TXVDoubles;
  ox, oy: Double;
begin
  Result := TXVMatrix.Translate(Num(Attr(E, 'Canvas.Left')) + Num(Attr(E, 'Margin')),
    Num(Attr(E, 'Canvas.Top')));
  if HasA(E, 'Margin') then
  begin
    org := SplitNums(Attr(E, 'Margin'));
    if Length(org) >= 2 then Result := TXVMatrix.Translate(Num(Attr(E, 'Canvas.Left')) + org[0],
      Num(Attr(E, 'Canvas.Top')) + org[1]);
  end;
  txt := PropValue(E, 'RenderTransform', sub);
  rt := TXVMatrix.Identity;
  if sub <> nil then rt := TransformOf(sub)
  else if txt <> '' then rt := ParseMatrixText(txt);
  if HasA(E, 'RenderTransformOrigin') then
  begin
    org := SplitNums(Attr(E, 'RenderTransformOrigin'));
    if Length(org) >= 2 then
    begin
      ox := org[0] * W; oy := org[1] * H;
      rt := XVMul(TXVMatrix.Translate(ox, oy), XVMul(rt, TXVMatrix.Translate(-ox, -oy)));
    end;
  end;
  Result := XVMul(Result, rt);
  // XPS uses the plain RenderTransform attribute as a matrix
end;

function TXamlReader.BrushPaint(B: TDOMElement; const Txt: string; Opacity: Double; const Box: TXVRect;
  const M: TXVMatrix): TXVPaint;
var
  n, mm: string;
  c: TXVColor;
  g: TXVGradient;
  st: TDOMNode;
  sub: TDOMElement;
  op: Double;
  v: TXVDoubles;
  rel: Boolean;
  bm, tm: TXVMatrix;
  i, k, r, gg, bb, a: Integer;
  t: string;
begin
  Result := XVNoPaint;
  if B = nil then
  begin
    if (Txt = '') or SameText(Txt, 'Transparent') then Exit;
    if ParseColor(Txt, c) then Result := XVSolid(XVMulAlpha(c, Opacity));
    if (Result.Kind = pkSolid) and ((Result.Color shr 24) = 0) then Result := XVNoPaint;
    Exit;
  end;
  n := LName(B);
  op := Opacity * Num(Attr(B, 'Opacity'), 1);
  if n = 'SolidColorBrush' then
  begin
    t := Attr(B, 'Color');
    if t = '' then
    begin
      sub := PropElem(B, 'Color');
      if sub <> nil then t := Trim(UTF8Encode(sub.TextContent));
    end;
    if ParseColor(t, c) then Result := XVSolid(XVMulAlpha(c, op));
    if (Result.Kind = pkSolid) and ((Result.Color shr 24) = 0) then Result := XVNoPaint;
    Exit;
  end;
  if (n = 'LinearGradientBrush') or (n = 'RadialGradientBrush') then
  begin
    g := Default(TXVGradient);
    mm := Attr(B, 'MappingMode');
    rel := not SameText(mm, 'Absolute');
    if n = 'LinearGradientBrush' then
    begin
      g.Kind := gkLinear;
      v := SplitNums(Attr(B, 'StartPoint'));
      if Length(v) >= 2 then begin g.X1 := v[0]; g.Y1 := v[1]; end else begin g.X1 := 0; g.Y1 := 0; end;
      v := SplitNums(Attr(B, 'EndPoint'));
      if Length(v) >= 2 then begin g.X2 := v[0]; g.Y2 := v[1]; end else begin g.X2 := 1; g.Y2 := 1; end;
      if HasA(B, 'Angle') and not HasA(B, 'StartPoint') then
      begin
        // Silverlight / old WPF shorthand
        g.X1 := 0; g.Y1 := 0;
        g.X2 := Cos(DegToRad(Num(Attr(B, 'Angle')))); g.Y2 := Sin(DegToRad(Num(Attr(B, 'Angle'))));
      end;
      g.Matrix := TXVMatrix.Identity;
    end
    else
    begin
      g.Kind := gkRadial;
      v := SplitNums(Attr(B, 'Center'));
      if Length(v) >= 2 then begin g.CX := v[0]; g.CY := v[1]; end else begin g.CX := 0.5; g.CY := 0.5; end;
      v := SplitNums(Attr(B, 'GradientOrigin'));
      if Length(v) >= 2 then begin g.FX := v[0]; g.FY := v[1]; end else begin g.FX := g.CX; g.FY := g.CY; end;
      // elliptic: unit circle scaled by RadiusX / RadiusY around the centre
      g.R := 1;
      g.Matrix := XVMul(TXVMatrix.Translate(g.CX, g.CY), XVMul(TXVMatrix.Scale(Num(Attr(B, 'RadiusX'), 0.5),
        Num(Attr(B, 'RadiusY'), 0.5)), TXVMatrix.Translate(-g.CX, -g.CY)));
      // keep the focus inside the gradient circle space
      g.FX := g.CX + (g.FX - g.CX) / Max(Num(Attr(B, 'RadiusX'), 0.5), 1e-9);
      g.FY := g.CY + (g.FY - g.CY) / Max(Num(Attr(B, 'RadiusY'), 0.5), 1e-9);
    end;
    t := LowerCase(Attr(B, 'SpreadMethod'));
    if t = 'reflect' then g.Spread := spReflect else if t = 'repeat' then g.Spread := spRepeat else g.Spread := spPad;
    // the brush transform, then the mapping (relative: the bounding box)
    bm := TXVMatrix.Identity;
    sub := PropElem(B, 'Transform');
    if sub <> nil then tm := TransformOf(sub) else if HasA(B, 'Transform') then tm := ParseMatrixText(Attr(B, 'Transform'))
    else tm := TXVMatrix.Identity;
    if rel then bm := TXVMatrix.Make(Max(Box.Width, 1e-9), 0, 0, Max(Box.Height, 1e-9), Box.Left, Box.Top);
    sub := PropElem(B, 'RelativeTransform');
    if sub <> nil then bm := XVMul(bm, TransformOf(sub));
    g.Matrix := XVMul(M, XVMul(tm, XVMul(bm, g.Matrix)));
    // stops: direct children or <...Brush.GradientStops>
    st := B.FirstChild;
    k := 0;
    r := 0; gg := 0; bb := 0; a := 0;
    while st <> nil do
    begin
      if st is TDOMElement then
      begin
        if Pos('.', LName(st)) > 0 then
        begin
          if SameText(Copy(LName(st), Pos('.', LName(st)) + 1, MaxInt), 'GradientStops') then st := st.FirstChild
          else begin st := st.NextSibling; Continue; end;
          Continue;
        end;
        if LName(st) = 'GradientStop' then
        begin
          if not ParseColor(Attr(st, 'Color'), c) then c := XV_BLACK;
          c := XVMulAlpha(c, op);
          SetLength(g.Stops, k + 1);
          g.Stops[k].Offset := EnsureRange(Num(Attr(st, 'Offset')), 0, 1);
          g.Stops[k].Color := c;
          Inc(r, XVColorR(c)); Inc(gg, XVColorG(c)); Inc(bb, XVColorB(c)); Inc(a, XVColorAlpha(c));
          Inc(k);
        end;
      end;
      st := st.NextSibling;
    end;
    if k = 0 then Exit;
    // stops may come in any order
    for i := 1 to k - 1 do
    begin
      t := '';
      if g.Stops[i].Offset < g.Stops[i - 1].Offset then
      begin
        c := g.Stops[i].Color; op := g.Stops[i].Offset;
        k := i - 1;
        while (k >= 0) and (g.Stops[k].Offset > op) do
        begin
          g.Stops[k + 1] := g.Stops[k];
          Dec(k);
        end;
        g.Stops[k + 1].Offset := op; g.Stops[k + 1].Color := c;
        k := Length(g.Stops);
      end;
    end;
    k := Length(g.Stops);
    if k = 1 then Exit(XVSolid(g.Stops[0].Color));
    Result := XVGradientPaint(Doc.AddGradient(g), XVRGBA(r div k, gg div k, bb div k, a div k));
    Exit;
  end;
  // image, visual and drawing brushes: a neutral grey
  if (n = 'ImageBrush') or (n = 'VisualBrush') or (n = 'DrawingBrush') then
    Result := XVSolid(XVMulAlpha($FF808080, op));
end;

function TXamlReader.MakePaint(E: TDOMElement; const Prop: string; Opacity: Double; const Box: TXVRect;
  const M: TXVMatrix): TXVPaint;
var
  sub: TDOMElement;
  txt: string;
begin
  txt := PropValue(E, Prop, sub);
  Result := BrushPaint(sub, txt, Opacity, Box, M);
end;

function DashesFrom(const S: string; W: Double): TXVDoubles;
var v: TXVDoubles; i: Integer;
begin
  Result := nil;
  v := SplitNums(S);
  if Length(v) < 1 then Exit;
  if Odd(Length(v)) then
  begin
    SetLength(Result, 2 * Length(v));
    for i := 0 to High(Result) do Result[i] := v[i mod Length(v)] * W;
  end
  else
  begin
    SetLength(Result, Length(v));
    for i := 0 to High(v) do Result[i] := v[i] * W;
  end;
end;

function CapOf(const S: string): TXVLineCap;
begin
  if SameText(S, 'Round') then Result := lcRound
  else if SameText(S, 'Square') then Result := lcSquare
  else Result := lcButt;
end;

function JoinOf(const S: string): TXVLineJoin;
begin
  if SameText(S, 'Round') then Result := ljRound
  else if SameText(S, 'Bevel') then Result := ljBevel
  else Result := ljMiter;
end;

function TXamlReader.ShapeStroke(E: TDOMElement; Opacity: Double; const Box: TXVRect; const M: TXVMatrix): TXVStroke;
var w, sc: Double;
begin
  Result := XVNoStroke;
  Result.Paint := MakePaint(E, 'Stroke', Opacity, Box, M);
  if Result.Paint.Kind = pkNone then Exit;
  sc := M.ScaleFactor;
  w := Num(Attr(E, 'StrokeThickness'), 1);
  if w <= 0 then begin Result.Paint := XVNoPaint; Exit; end;
  Result.Width := w * sc;
  Result.Cap := CapOf(Attr(E, 'StrokeStartLineCap'));
  if HasA(E, 'StrokeEndLineCap') then Result.Cap := CapOf(Attr(E, 'StrokeEndLineCap'));
  Result.Join := JoinOf(Attr(E, 'StrokeLineJoin'));
  Result.MiterLimit := Num(Attr(E, 'StrokeMiterLimit'), 10);
  if HasA(E, 'StrokeDashArray') then
  begin
    Result.Dashes := DashesFrom(Attr(E, 'StrokeDashArray'), Result.Width);
    Result.DashOffset := Num(Attr(E, 'StrokeDashOffset')) * Result.Width;
  end;
end;

function TXamlReader.PenStroke(Pen: TDOMElement; Opacity: Double; const Box: TXVRect; const M: TXVMatrix): TXVStroke;
var
  w: Double;
  sub: TDOMElement;
begin
  Result := XVNoStroke;
  if Pen = nil then Exit;
  Result.Paint := MakePaint(Pen, 'Brush', Opacity, Box, M);
  if Result.Paint.Kind = pkNone then Exit;
  w := Num(Attr(Pen, 'Thickness'), 1);
  Result.Width := w * M.ScaleFactor;
  Result.Cap := CapOf(Attr(Pen, 'StartLineCap'));
  Result.Join := JoinOf(Attr(Pen, 'LineJoin'));
  Result.MiterLimit := Num(Attr(Pen, 'MiterLimit'), 10);
  sub := PropElem(Pen, 'DashStyle');
  if (sub <> nil) and HasA(sub, 'Dashes') then
    Result.Dashes := DashesFrom(Attr(sub, 'Dashes'), Result.Width);
end;

// a geometry element or mini-language text in the element's own space
function TXamlReader.GeometryOf(G: TDOMElement; const Txt: string; out P: TXVPath; out Rule: TXVFillRule): Boolean;
var
  s, n: string;
  c, seg: TDOMNode;
  q: TXVPath;
  r2: TXVFillRule;
  v: TXVDoubles;
  sub: TDOMElement;
  m: TXVMatrix;
  i: Integer;
  closed, filled: Boolean;
  cx, cy: Double;
  fig: TDOMNode;
begin
  P := Default(TXVPath);
  P.Clear;
  Rule := frEvenOdd;
  if G = nil then
  begin
    s := Trim(Txt);
    if s = '' then Exit(False);
    // fill rule prefix of the mini-language: F0 even-odd, F1 non-zero
    if (Length(s) >= 2) and (UpCase(s[1]) = 'F') and (s[2] in ['0', '1']) then
    begin
      if s[2] = '1' then Rule := frNonZero;
      Delete(s, 1, 2);
    end;
    XVParseSvgPathData(s, P);
    Exit(P.NCmd > 0);
  end;
  n := LName(G);
  if HasA(G, 'FillRule') then
    if SameText(Attr(G, 'FillRule'), 'NonZero') then Rule := frNonZero;
  if (n = 'PathGeometry') or (n = 'StreamGeometry') then
  begin
    if HasA(G, 'Figures') then GeometryOf(nil, Attr(G, 'Figures'), P, r2);
    fig := G.FirstChild;
    while fig <> nil do
    begin
      if fig is TDOMElement then
      begin
        if Pos('.', LName(fig)) > 0 then
        begin
          if SameText(Copy(LName(fig), Pos('.', LName(fig)) + 1, MaxInt), 'Figures') then fig := fig.FirstChild
          else fig := fig.NextSibling;
          Continue;
        end;
        if LName(fig) = 'PathFigure' then
        begin
          v := SplitNums(Attr(fig, 'StartPoint'));
          if Length(v) >= 2 then P.MoveTo(v[0], v[1]) else P.MoveTo(0, 0);
          closed := SameText(Attr(fig, 'IsClosed'), 'True');
          filled := not SameText(Attr(fig, 'IsFilled'), 'False');
          seg := fig.FirstChild;
          while seg <> nil do
          begin
            if seg is TDOMElement then
            begin
              if Pos('.', LName(seg)) > 0 then begin seg := seg.FirstChild; Continue; end;
              n := LName(seg);
              if n = 'LineSegment' then
              begin
                v := SplitNums(Attr(seg, 'Point'));
                if Length(v) >= 2 then P.LineTo(v[0], v[1]);
              end
              else if n = 'PolyLineSegment' then
              begin
                v := SplitNums(Attr(seg, 'Points'));
                for i := 0 to Length(v) div 2 - 1 do P.LineTo(v[2 * i], v[2 * i + 1]);
              end
              else if n = 'BezierSegment' then
              begin
                v := SplitNums(Attr(seg, 'Point1') + ' ' + Attr(seg, 'Point2') + ' ' + Attr(seg, 'Point3'));
                if Length(v) >= 6 then P.CubicTo(v[0], v[1], v[2], v[3], v[4], v[5]);
              end
              else if n = 'PolyBezierSegment' then
              begin
                v := SplitNums(Attr(seg, 'Points'));
                for i := 0 to Length(v) div 6 - 1 do
                  P.CubicTo(v[6 * i], v[6 * i + 1], v[6 * i + 2], v[6 * i + 3], v[6 * i + 4], v[6 * i + 5]);
              end
              else if n = 'QuadraticBezierSegment' then
              begin
                v := SplitNums(Attr(seg, 'Point1') + ' ' + Attr(seg, 'Point2'));
                if Length(v) >= 4 then P.QuadTo(v[0], v[1], v[2], v[3]);
              end
              else if n = 'PolyQuadraticBezierSegment' then
              begin
                v := SplitNums(Attr(seg, 'Points'));
                for i := 0 to Length(v) div 4 - 1 do P.QuadTo(v[4 * i], v[4 * i + 1], v[4 * i + 2], v[4 * i + 3]);
              end
              else if n = 'ArcSegment' then
              begin
                v := SplitNums(Attr(seg, 'Point') + ' ' + Attr(seg, 'Size'));
                if Length(v) >= 4 then
                  P.ArcTo(v[2], v[3], Num(Attr(seg, 'RotationAngle')), SameText(Attr(seg, 'IsLargeArc'), 'True'),
                    SameText(Attr(seg, 'SweepDirection'), 'Clockwise'), v[0], v[1]);
              end;
            end;
            seg := seg.NextSibling;
          end;
          if closed then P.Close;
          if not filled then ;
        end;
      end;
      fig := fig.NextSibling;
    end;
  end
  else if n = 'EllipseGeometry' then
  begin
    v := SplitNums(Attr(G, 'Center'));
    if Length(v) >= 2 then begin cx := v[0]; cy := v[1]; end else begin cx := 0; cy := 0; end;
    P.AddEllipse(cx, cy, Num(Attr(G, 'RadiusX')), Num(Attr(G, 'RadiusY')));
  end
  else if n = 'RectangleGeometry' then
  begin
    v := SplitNums(Attr(G, 'Rect'));
    if Length(v) >= 4 then P.AddRoundRect(v[0], v[1], v[2], v[3], Num(Attr(G, 'RadiusX')), Num(Attr(G, 'RadiusY')));
  end
  else if n = 'LineGeometry' then
  begin
    v := SplitNums(Attr(G, 'StartPoint') + ' ' + Attr(G, 'EndPoint'));
    if Length(v) >= 4 then begin P.MoveTo(v[0], v[1]); P.LineTo(v[2], v[3]); end;
  end
  else if (n = 'GeometryGroup') or (n = 'CombinedGeometry') then
  begin
    c := G.FirstChild;
    while c <> nil do
    begin
      if c is TDOMElement then
      begin
        if Pos('.', LName(c)) > 0 then
        begin
          sub := TDOMElement(c.FirstChild);
          while (sub <> nil) and not (sub is TDOMElement) do sub := TDOMElement(sub.NextSibling);
          // CombinedGeometry.Geometry1 / Geometry2, GeometryGroup.Children
          while sub <> nil do
          begin
            if (sub is TDOMElement) and GeometryOf(sub, '', q, r2) then P.Append(q);
            sub := TDOMElement(sub.NextSibling);
          end;
        end
        else if GeometryOf(TDOMElement(c), '', q, r2) then P.Append(q);
      end;
      c := c.NextSibling;
    end;
    if n = 'CombinedGeometry' then Rule := frNonZero;
  end;
  // the geometry's own transform
  sub := PropElem(G, 'Transform');
  if sub <> nil then
  begin
    m := TransformOf(sub);
    P.Transform(m);
  end
  else if HasA(G, 'Transform') then P.Transform(ParseMatrixText(Attr(G, 'Transform')));
  Result := P.NCmd > 0;
end;

procedure TXamlReader.EmitShape(E: TDOMElement; const P: TXVPath; Rule: TXVFillRule; const St: TXState);
var
  box: TXVRect;
  fill: TXVPaint;
  stroke: TXVStroke;
  q: TXVPath;
begin
  if not P.Bounds(box) then Exit;
  fill := MakePaint(E, 'Fill', 1, box, St.M);
  stroke := ShapeStroke(E, 1, box, St.M);
  if (fill.Kind = pkNone) and (stroke.Paint.Kind = pkNone) then Exit;
  q := P.Copy;
  q.Transform(St.M);
  Doc.AddPath(q, fill, stroke, Rule, 1);
end;

procedure TXamlReader.EmitText(E: TDOMElement; const St: TXState);
var
  font: TXVFont;
  txt, w: string;
  c: TDOMNode;
  fill: TXVPaint;
  m: TXVMatrix;
  idx, first: Integer;
  size: Double;

  procedure Style(N: TDOMNode; var F: TXVFont);
  begin
    if HasA(N, 'FontFamily') then F.Family := Trim(Copy(Attr(N, 'FontFamily') + ',', 1, Pos(',', Attr(N, 'FontFamily') + ',') - 1));
    if HasA(N, 'FontSize') then F.Size := Num(Attr(N, 'FontSize'), 12);
    w := LowerCase(Attr(N, 'FontWeight'));
    if (w = 'bold') or (w = 'semibold') or (w = 'extrabold') or (w = 'black') or (w = 'heavy') or (w = 'ultrabold') then F.Weight := 700
    else if w <> '' then F.Weight := 400;
    if HasA(N, 'FontStyle') then F.Italic := SameText(Attr(N, 'FontStyle'), 'Italic') or SameText(Attr(N, 'FontStyle'), 'Oblique');
    if Pos('underline', LowerCase(Attr(N, 'TextDecorations'))) > 0 then F.Underline := True;
    if Pos('strikethrough', LowerCase(Attr(N, 'TextDecorations'))) > 0 then F.Strike := True;
  end;

  procedure AddRun(const S: string; N: TDOMElement; const F: TXVFont);
  var p: TXVPaint;
  begin
    if S = '' then Exit;
    if (N <> nil) and (HasA(N, 'Foreground') or (PropElem(N, 'Foreground') <> nil)) then
      p := MakePaint(N, 'Foreground', 1, XVRect(0, 0, 100, F.Size), m)
    else p := fill;
    if first < 0 then
    begin
      idx := Doc.AddText(S, F, m, p);
      first := idx;
    end
    else
    begin
      idx := Doc.AddText(S, F, TXVMatrix.Make(m.A, m.B, m.C, m.D, 0, 0), p);
      Doc.Elements[idx].Continued := True;
    end;
  end;

type
  TPend = record
    S: string;
    N: TDOMElement;
    F: TXVFont;
    Break_: Boolean;
  end;
var
  rf: TXVFont;
  runs: array of TPend;
  i, j: Integer;

  procedure Queue(const S: string; N: TDOMElement; const F: TXVFont; Brk: Boolean);
  var k: Integer; t: string; sp: Boolean;
  begin
    // white space collapses to single blanks, as in a text block
    t := '';
    sp := False;
    for k := 1 to Length(S) do
      if S[k] in [' ', #9, #10, #13] then
      begin
        if not sp then t := t + ' ';
        sp := True;
      end
      else
      begin
        t := t + S[k];
        sp := False;
      end;
    SetLength(runs, Length(runs) + 1);
    runs[High(runs)].S := t;
    runs[High(runs)].N := N;
    runs[High(runs)].F := F;
    runs[High(runs)].Break_ := Brk;
  end;

begin
  font := XVDefaultFont;
  font.Family := 'Segoe UI';
  font.Size := 12;
  Style(E, font);
  size := font.Size;
  // the text block's top-left: the first baseline is about one em lower
  m := XVMul(St.M, XVMul(ElemTransform(E, 0, 0), TXVMatrix.Translate(0, size * 0.96)));
  fill := MakePaint(E, 'Foreground', 1, XVRect(0, 0, 100, size), m);
  if (fill.Kind = pkNone) and not HasA(E, 'Foreground') then fill := XVSolid(XV_BLACK);
  first := -1;
  runs := nil;
  txt := Attr(E, 'Text');
  if txt <> '' then Queue(txt, nil, font, False);
  c := E.FirstChild;
  while c <> nil do
  begin
    if c.NodeType = TEXT_NODE then Queue(UTF8Encode(c.NodeValue), nil, font, False)
    else if (c is TDOMElement) and (LName(c) = 'Run') then
    begin
      rf := font;
      Style(c, rf);
      if HasA(c, 'Text') then Queue(Attr(c, 'Text'), TDOMElement(c), rf, False)
      else Queue(UTF8Encode(c.TextContent), TDOMElement(c), rf, False);
    end
    else if (c is TDOMElement) and (LName(c) = 'LineBreak') then Queue('', nil, font, True);
    c := c.NextSibling;
  end;
  // blanks at the start and end of each line go away, one blank between runs
  for i := 0 to High(runs) do
    if (i = 0) or runs[i - 1].Break_ then
    begin
      j := i;
      while (j <= High(runs)) and not runs[j].Break_ do
      begin
        runs[j].S := TrimLeft(runs[j].S);
        if runs[j].S <> '' then Break;
        Inc(j);
      end;
    end;
  for i := High(runs) downto 0 do
    if (i = High(runs)) or runs[i + 1].Break_ then
    begin
      j := i;
      while (j >= 0) and not runs[j].Break_ do
      begin
        runs[j].S := TrimRight(runs[j].S);
        if runs[j].S <> '' then Break;
        Dec(j);
      end;
    end;
  for i := 1 to High(runs) do
    if (runs[i].S <> '') and (runs[i].S[1] = ' ') and (runs[i - 1].S <> '') and
       (runs[i - 1].S[Length(runs[i - 1].S)] = ' ') then Delete(runs[i].S, 1, 1);
  for i := 0 to High(runs) do
    if runs[i].Break_ then
    begin
      m := XVMul(m, TXVMatrix.Translate(0, size * 1.33));
      first := -1;
    end
    else AddRun(runs[i].S, runs[i].N, runs[i].F);
end;

// XPS Glyphs: OriginX / OriginY is the baseline start
procedure TXamlReader.EmitGlyphs(E: TDOMElement; const St: TXState);
var
  font: TXVFont;
  m: TXVMatrix;
  s, uri: string;
  fill: TXVPaint;
  idx: Integer;
begin
  s := Attr(E, 'UnicodeString');
  if (s <> '') and (Copy(s, 1, 2) = '{}') then Delete(s, 1, 2);
  if s = '' then Exit;
  font := XVDefaultFont;
  font.Size := Num(Attr(E, 'FontRenderingEmSize'), 12);
  uri := Attr(E, 'FontUri');
  font.Family := ChangeFileExt(ExtractFileName(StringReplace(uri, '/', '\', [rfReplaceAll])), '');
  if (font.Family = '') or (Length(font.Family) > 30) or (Pos('-', font.Family) > 8) then font.Family := 'Arial';
  if Pos('Bold', Attr(E, 'StyleSimulations')) > 0 then font.Weight := 700;
  if Pos('Italic', Attr(E, 'StyleSimulations')) > 0 then font.Italic := True;
  m := XVMul(St.M, XVMul(ElemTransform(E, 0, 0), TXVMatrix.Translate(Num(Attr(E, 'OriginX')), Num(Attr(E, 'OriginY')))));
  fill := MakePaint(E, 'Fill', 1, XVRect(0, -font.Size, font.Size * Length(s) * 0.5, 0), m);
  if fill.Kind = pkNone then Exit;
  idx := Doc.AddText(s, font, m, fill);
  if idx < 0 then ;
end;

// DrawingGroup / GeometryDrawing trees
procedure TXamlReader.Drawing(E: TDOMElement; const St: TXState);
var
  n, txt: string;
  c: TDOMNode;
  S2: TXState;
  P: TXVPath;
  rule: TXVFillRule;
  sub, pen: TDOMElement;
  box: TXVRect;
  fill: TXVPaint;
  stroke: TXVStroke;
  clip: Integer;
  cp: TXVPath;
  grp: Boolean;
begin
  n := LName(E);
  if (n = 'DrawingImage') then
  begin
    sub := PropElem(E, 'Drawing');
    if sub <> nil then Drawing(sub, St);
    c := E.FirstChild;
    while c <> nil do
    begin
      if (c is TDOMElement) and (Pos('.', LName(c)) = 0) then Drawing(TDOMElement(c), St);
      c := c.NextSibling;
    end;
    Exit;
  end;
  if n = 'DrawingGroup' then
  begin
    S2 := St;
    sub := PropElem(E, 'Transform');
    if sub <> nil then S2.M := XVMul(St.M, TransformOf(sub))
    else if HasA(E, 'Transform') then S2.M := XVMul(St.M, ParseMatrixText(Attr(E, 'Transform')));
    clip := -1;
    txt := PropValue(E, 'ClipGeometry', sub);
    if GeometryOf(sub, txt, cp, rule) then
    begin
      cp.Transform(S2.M);
      clip := Doc.AddClip(cp, rule);
    end;
    grp := (clip >= 0) or (Num(Attr(E, 'Opacity'), 1) < 0.999);
    if grp then Doc.BeginGroup(clip, Num(Attr(E, 'Opacity'), 1));
    c := E.FirstChild;
    while c <> nil do
    begin
      if c is TDOMElement then
      begin
        if Pos('.', LName(c)) > 0 then
        begin
          if SameText(Copy(LName(c), Pos('.', LName(c)) + 1, MaxInt), 'Children') then
          begin
            sub := TDOMElement(c.FirstChild);
            while sub <> nil do
            begin
              if sub is TDOMElement then Drawing(sub, S2);
              sub := TDOMElement(sub.NextSibling);
            end;
          end;
        end
        else Drawing(TDOMElement(c), S2);
      end;
      c := c.NextSibling;
    end;
    if grp then Doc.EndGroup;
    Exit;
  end;
  if n = 'GeometryDrawing' then
  begin
    txt := PropValue(E, 'Geometry', sub);
    if not GeometryOf(sub, txt, P, rule) then Exit;
    if not P.Bounds(box) then Exit;
    fill := MakePaint(E, 'Brush', 1, box, St.M);
    PropValue(E, 'Pen', pen);
    stroke := PenStroke(pen, 1, box, St.M);
    if (fill.Kind = pkNone) and (stroke.Paint.Kind = pkNone) then Exit;
    P.Transform(St.M);
    Doc.AddPath(P, fill, stroke, rule, 1);
  end;
end;

procedure TXamlReader.Node(E: TDOMElement; const St: TXState);
var
  n, txt: string;
  S2: TXState;
  P: TXVPath;
  rule: TXVFillRule;
  sub: TDOMElement;
  c: TDOMNode;
  w, h, rx, ry, bt: Double;
  v: TXVDoubles;
  i, clip: Integer;
  cp: TXVPath;
  grp: Boolean;
  op: Double;
  box: TXVRect;
  fill: TXVPaint;
  stroke: TXVStroke;
  inner: TXVPath;
begin
  n := LName(E);
  if Pos('.', n) > 0 then Exit;                         // property element
  if SameText(Attr(E, 'Visibility'), 'Collapsed') or SameText(Attr(E, 'Visibility'), 'Hidden') then Exit;
  if (n = 'ResourceDictionary') or (n = 'Style') or (n = 'Storyboard') then Exit;
  w := Num(Attr(E, 'Width')); h := Num(Attr(E, 'Height'));
  S2 := St;
  S2.M := XVMul(St.M, ElemTransform(E, w, h));
  op := Num(Attr(E, 'Opacity'), 1);
  // clip geometry in the element's space
  clip := -1;
  txt := PropValue(E, 'Clip', sub);
  if GeometryOf(sub, txt, cp, rule) then
  begin
    cp.Transform(S2.M);
    clip := Doc.AddClip(cp, rule);
  end;
  grp := (clip >= 0) or (op < 0.999);
  if grp then Doc.BeginGroup(clip, op);
  try
    if (n = 'Canvas') or (n = 'Grid') or (n = 'StackPanel') or (n = 'Viewbox') or (n = 'FixedPage') or
       (n = 'Page') or (n = 'Window') or (n = 'UserControl') or (n = 'Border') or (n = 'DockPanel') or
       (n = 'WrapPanel') or (n = 'Panel') then
    begin
      if (n = 'Border') or (HasA(E, 'Background') or (PropElem(E, 'Background') <> nil)) then
      begin
        // background and border of the box
        if (w > 0) and (h > 0) then
        begin
          P := Default(TXVPath); P.Clear;
          v := SplitNums(Attr(E, 'CornerRadius'));
          if Length(v) > 0 then rx := v[0] else rx := 0;
          P.AddRoundRect(0, 0, w, h, rx, rx);
          box := XVRect(0, 0, w, h);
          fill := MakePaint(E, 'Background', 1, box, S2.M);
          stroke := XVNoStroke;
          stroke.Paint := MakePaint(E, 'BorderBrush', 1, box, S2.M);
          v := SplitNums(Attr(E, 'BorderThickness'));
          if Length(v) > 0 then bt := v[0] else bt := 0;
          if bt <= 0 then stroke.Paint := XVNoPaint;
          stroke.Width := bt * S2.M.ScaleFactor;
          P.Transform(S2.M);
          Doc.AddPath(P, fill, stroke, frNonZero);
        end;
      end;
      c := E.FirstChild;
      while c <> nil do
      begin
        if c is TDOMElement then
        begin
          if (LName(c) = 'DrawingImage') or (LName(c) = 'DrawingGroup') then Drawing(TDOMElement(c), S2)
          else Node(TDOMElement(c), S2);
        end;
        c := c.NextSibling;
      end;
    end
    else if n = 'Path' then
    begin
      txt := PropValue(E, 'Data', sub);
      if GeometryOf(sub, txt, P, rule) then
      begin
        // Stretch="Fill" / "Uniform": the geometry fills Width x Height
        if (w > 0) and (h > 0) and (Attr(E, 'Stretch') <> '') and not SameText(Attr(E, 'Stretch'), 'None') and P.Bounds(box) and
           (box.Width > 0) and (box.Height > 0) then
        begin
          if SameText(Attr(E, 'Stretch'), 'Fill') then
            P.Transform(TXVMatrix.Make(w / box.Width, 0, 0, h / box.Height, -box.Left * w / box.Width, -box.Top * h / box.Height))
          else
            P.Transform(TXVMatrix.Make(Min(w / box.Width, h / box.Height), 0, 0, Min(w / box.Width, h / box.Height),
              -box.Left * Min(w / box.Width, h / box.Height), -box.Top * Min(w / box.Width, h / box.Height)));
        end;
        EmitShape(E, P, rule, S2);
      end;
    end
    else if n = 'Rectangle' then
    begin
      if (w > 0) and (h > 0) then
      begin
        P := Default(TXVPath); P.Clear;
        rx := Num(Attr(E, 'RadiusX')); ry := Num(Attr(E, 'RadiusY'));
        P.AddRoundRect(0, 0, w, h, rx, ry);
        EmitShape(E, P, frNonZero, S2);
      end;
    end
    else if n = 'Ellipse' then
    begin
      if (w > 0) and (h > 0) then
      begin
        P := Default(TXVPath); P.Clear;
        P.AddEllipse(w / 2, h / 2, w / 2, h / 2);
        EmitShape(E, P, frNonZero, S2);
      end;
    end
    else if n = 'Line' then
    begin
      P := Default(TXVPath); P.Clear;
      P.MoveTo(Num(Attr(E, 'X1')), Num(Attr(E, 'Y1')));
      P.LineTo(Num(Attr(E, 'X2')), Num(Attr(E, 'Y2')));
      EmitShape(E, P, frNonZero, S2);
    end
    else if (n = 'Polyline') or (n = 'Polygon') then
    begin
      v := SplitNums(Attr(E, 'Points'));
      P := Default(TXVPath); P.Clear;
      for i := 0 to Length(v) div 2 - 1 do
        if i = 0 then P.MoveTo(v[0], v[1]) else P.LineTo(v[2 * i], v[2 * i + 1]);
      if n = 'Polygon' then P.Close;
      if SameText(Attr(E, 'FillRule'), 'NonZero') then rule := frNonZero else rule := frEvenOdd;
      if P.NCmd > 0 then EmitShape(E, P, rule, S2);
    end
    else if (n = 'TextBlock') or (n = 'Label') then EmitText(E, St)
    else if n = 'Glyphs' then EmitGlyphs(E, St)
    else if (n = 'DrawingImage') or (n = 'DrawingGroup') or (n = 'GeometryDrawing') then Drawing(E, S2)
    else if n = 'Image' then
    begin
      // the source is a resource: a drawing image or nothing we can read
      txt := PropValue(E, 'Source', sub);
      if sub <> nil then Drawing(sub, S2);
    end
    else
    begin
      // unknown containers: their children
      c := E.FirstChild;
      while c <> nil do
      begin
        if c is TDOMElement then Node(TDOMElement(c), S2);
        c := c.NextSibling;
      end;
    end;
  finally
    if grp then Doc.EndGroup;
  end;
  if inner.NCmd = 0 then ;
end;

procedure TXamlReader.Run(const Data: TBytes);
var
  ss: TStringStream;
  parser: TDOMParser;
  src: TXMLInputSource;
  root: TDOMElement;
  St: TXState;
  s: string;
  w, h: Double;
  r: TXVRect;
begin
  SetLength(s, Length(Data));
  if Length(Data) > 0 then Move(Data[0], s[1], Length(Data));
  if Copy(s, 1, 3) = #$EF#$BB#$BF then Delete(s, 1, 3);
  // UTF-16 files
  if (Length(Data) >= 2) and (Data[0] = $FF) and (Data[1] = $FE) then s := XVUtf16ToUtf8(Data, 2, Length(Data) - 2);
  ss := TStringStream.Create(s);
  try
    parser := TDOMParser.Create;
    src := TXMLInputSource.Create(ss);
    try
      parser.Options.PreserveWhitespace := True;
      parser.Parse(src, XDoc);
    finally
      src.Free;
      parser.Free;
    end;
  finally
    ss.Free;
  end;
  root := XDoc.DocumentElement;
  if root = nil then raise EXVError.Create('XAML: no root element');
  CollectRes(root);
  St.M := TXVMatrix.Identity;
  St.Opacity := 1;
  w := Num(Attr(root, 'Width')); h := Num(Attr(root, 'Height'));
  if (LName(root) = 'ResourceDictionary') then
  begin
    // icon dictionaries: the first drawing image or canvas
    s := '';
    if Res.Count > 0 then
      if (LName(TDOMElement(Res.Objects[0])) = 'DrawingImage') or (LName(TDOMElement(Res.Objects[0])) = 'DrawingGroup') then
        Drawing(TDOMElement(Res.Objects[0]), St)
      else Node(TDOMElement(Res.Objects[0]), St);
  end
  else if (LName(root) = 'DrawingImage') or (LName(root) = 'DrawingGroup') then Drawing(root, St)
  else
  begin
    // the root's own offset does not count
    root.RemoveAttribute('Canvas.Left');
    root.RemoveAttribute('Canvas.Top');
    root.RemoveAttribute('Margin');
    Node(root, St);
  end;
  if (w > 0) and (h > 0) then Doc.SetPageSize(w, h)
  else if Doc.ContentBounds(r) then
  begin
    Doc.ViewBox := XVRect(Min(0, r.Left), Min(0, r.Top), r.Right, r.Bottom);
    Doc.Width := Doc.ViewBox.Width;
    Doc.Height := Doc.ViewBox.Height;
  end;
end;

function XVIsXAML(const Data: TBytes): Boolean;
var
  s: string;
  n: Integer;
begin
  n := Min(Length(Data), 2048);
  SetLength(s, n);
  if n > 0 then Move(Data[0], s[1], n);
  Result := (Pos('schemas.microsoft.com/winfx/2006/xaml', s) > 0) or
    (Pos('schemas.microsoft.com/xps/2005/06', s) > 0) or (Pos('schemas.microsoft.com/client/2007', s) > 0) or
    (Pos('<FixedPage', s) > 0);
end;

procedure XVReadXAMLDoc(Doc: TXVDocument; const Data: TBytes);
var R: TXamlReader;
begin
  R := TXamlReader.Create;
  try
    R.Doc := Doc;
    R.Res := TStringList.Create;
    try
      R.Run(Data);
    finally
      R.Res.Free;
      R.XDoc.Free;
    end;
  finally
    R.Free;
  end;
end;

initialization
  XVRegisterReader('XAML', 'xaml;fpage', XVIsXAML, XVReadXAMLDoc);
end.
