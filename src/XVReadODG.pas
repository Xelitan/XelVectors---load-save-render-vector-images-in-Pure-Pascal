unit XVReadODG;

{$mode delphi}{$H+}
{$R-}{$Q-}

// XelVectors - OpenDocument Drawing reader (.odg, .otg; flat .fodg).
//
// content.xml and styles.xml are read from the package; graphic styles are
// resolved through their parents and the default style. One page is drawn
// (Doc.LoadPage), master page objects first: rectangles, ellipses / circles
// (sections, cuts, arcs), lines, polylines, polygons, regular polygons,
// paths, connectors, measures, custom shapes (enhanced geometry with
// equations, modifiers and the full path command set), frames with text
// boxes and images, groups and captions. Fills: solid, the ODF gradient
// styles, hatches, bitmaps; opacity; strokes with dashes, caps, joins and
// line end markers; shadows; text in shapes and text boxes.

interface

uses
  SysUtils, Classes, Math, DOM, XMLRead, XVModel, XVZip, XVImageCodec, XVReadSVG;

function XVIsODG(const Data: TBytes): Boolean;
procedure XVReadODGDoc(Doc: TXVDocument; const Data: TBytes);

implementation

type
  TOdgStyle = record
    Name, Parent, Family: string;
    Props: TStringList;            // local-name=value of all *-properties
  end;

  TOdgBox = record
    X, Y, W, H: Double;
  end;

  { TOdgReader }

  TOdgReader = class
    Doc: TXVDocument;
    Zip: TBytes;
    ZipList: TXVZipEntries;
    Content, Styles: TXMLDocument;
    StyleList: array of TOdgStyle;
    StyleIdx: TStringList;
    DefaultStyle: Integer;
    Named: TStringList;            // "kind:name" -> element (gradients, hatches, dashes, markers, images)
    Fonts: TStringList;            // font face name -> family
    function LName(N: TDOMNode): string;
    function Attr(N: TDOMNode; const Name: string): string;
    function Len(const S: string; Ref: Double = 0; Def: Double = 0): Double;
    procedure LoadStyles(Root: TDOMNode; const Prefix: string);
    procedure CollectNamed(N: TDOMNode);
    function FindStyle(const Name: string): Integer;
    function Prop(const StyleName, Key: string; const Def: string = ''; UseDefault: Boolean = True): string;
    function ParseDoc(const Name: string): TXMLDocument;
    function ParseColor(const S: string; out C: TXVColor): Boolean;
    function ShapeMatrix(E: TDOMElement; const Parent: TXVMatrix; out Box: TOdgBox): TXVMatrix;
    function MakeFill(const St: string; const P: TXVPath; out Hatch: Boolean): TXVPaint;
    function MakeStroke(const St: string; const M: TXVMatrix): TXVStroke;
    procedure HatchFill(const St: string; const P: TXVPath);
    procedure Markers(const St: string; const P: TXVPath; const M: TXVMatrix);
    procedure Emit(E: TDOMElement; const St: string; const LocalPath: TXVPath; const M: TXVMatrix; Closed: Boolean;
      Rule: TXVFillRule = frEvenOdd);
    procedure ShapeText(E: TDOMElement; const St: string; const Box: TOdgBox; const M: TXVMatrix; TextBox: Boolean);
    function CustomShape(E: TDOMElement; const Box: TOdgBox; out Parts: TArray<TXVPath>; out NoFill, NoStroke: TArray<Boolean>): Boolean;
    procedure Shape(E: TDOMElement; const Parent: TXVMatrix);
    procedure Children(E: TDOMNode; const M: TXVMatrix);
    function ParseFlat: TXMLDocument;
    procedure Run;
  end;

// ------------------------------ helpers ------------------------------------

function TOdgReader.LName(N: TDOMNode): string;
var s: string; p: Integer;
begin
  s := UTF8Encode(N.NodeName);
  p := Pos(':', s);
  if p > 0 then Delete(s, 1, p);
  Result := s;
end;

function TOdgReader.Attr(N: TDOMNode; const Name: string): string;
var a: TDOMNode;
begin
  Result := '';
  if (N = nil) or (N.Attributes = nil) then Exit;
  a := N.Attributes.GetNamedItem(UTF8Decode(Name));
  if a <> nil then Result := UTF8Encode(a.NodeValue);
end;

// lengths in pixels (96 dpi); percentages of Ref
function TOdgReader.Len(const S: string; Ref: Double; Def: Double): Double;
var
  t, u: string;
  i: Integer;
  v: Double;
begin
  t := Trim(S);
  if t = '' then Exit(Def);
  i := Length(t);
  while (i > 0) and (t[i] in ['a'..'z', 'A'..'Z', '%']) do Dec(i);
  u := LowerCase(Copy(t, i + 1, MaxInt));
  v := XVStrToFloat(Copy(t, 1, i), Def);
  if u = 'cm' then Result := v * 96 / 2.54
  else if u = 'mm' then Result := v * 96 / 25.4
  else if u = 'in' then Result := v * 96
  else if u = 'pt' then Result := v * 96 / 72
  else if u = 'pc' then Result := v * 16
  else if u = '%' then Result := v * Ref / 100
  else Result := v;
end;

function TOdgReader.ParseColor(const S: string; out C: TXVColor): Boolean;
begin
  Result := XVParseCssColor(S, C, XV_BLACK);
end;

function TOdgReader.ParseDoc(const Name: string): TXMLDocument;
var
  d: TBytes;
  ss: TStringStream;
  s: string;
  parser: TDOMParser;
  src: TXMLInputSource;
begin
  Result := nil;
  d := XVZipReadName(Zip, ZipList, Name);
  if Length(d) = 0 then Exit;
  SetLength(s, Length(d));
  Move(d[0], s[1], Length(d));
  ss := TStringStream.Create(s);
  try
    parser := TDOMParser.Create;
    src := TXMLInputSource.Create(ss);
    try
      parser.Options.PreserveWhitespace := True;
      parser.Parse(src, Result);
    finally
      src.Free;
      parser.Free;
    end;
  finally
    ss.Free;
  end;
end;

function TOdgReader.ParseFlat: TXMLDocument;
var
  ss: TStringStream;
  s: string;
  parser: TDOMParser;
  src: TXMLInputSource;
begin
  Result := nil;
  SetLength(s, Length(Zip));
  if Length(Zip) > 0 then Move(Zip[0], s[1], Length(Zip));
  ss := TStringStream.Create(s);
  try
    parser := TDOMParser.Create;
    src := TXMLInputSource.Create(ss);
    try
      parser.Options.PreserveWhitespace := True;
      parser.Parse(src, Result);
    finally
      src.Free;
      parser.Free;
    end;
  finally
    ss.Free;
  end;
end;

procedure TOdgReader.LoadStyles(Root: TDOMNode; const Prefix: string);
var
  c, p: TDOMNode;
  n, i: Integer;
  st: TOdgStyle;
  nm: string;
begin
  if Root = nil then Exit;
  c := Root.FirstChild;
  while c <> nil do
  begin
    if c is TDOMElement then
    begin
      nm := LName(c);
      if (nm = 'style') or (nm = 'default-style') then
      begin
        st.Name := Attr(c, 'style:name');
        st.Parent := Attr(c, 'style:parent-style-name');
        st.Family := Attr(c, 'style:family');
        st.Props := TStringList.Create;
        p := c.FirstChild;
        while p <> nil do
        begin
          if (p is TDOMElement) and (Pos('properties', LName(p)) > 0) and (p.Attributes <> nil) then
            for i := 0 to p.Attributes.Length - 1 do
              // keys carry their group: "graphic:fill", "text:font-size" ...
              st.Props.Values[Copy(LName(p), 1, Pos('-properties', LName(p)) - 1) + ':' + LName(p.Attributes.Item[i])] :=
                UTF8Encode(p.Attributes.Item[i].NodeValue);
          p := p.NextSibling;
        end;
        n := Length(StyleList);
        SetLength(StyleList, n + 1);
        StyleList[n] := st;
        if nm = 'default-style' then
        begin
          if st.Family = 'graphic' then DefaultStyle := n;
        end
        else StyleIdx.AddObject(st.Name, TObject(PtrInt(n)));
      end
      else if (nm = 'font-face') then
        Fonts.Values[Attr(c, 'style:name')] := StringReplace(Attr(c, 'svg:font-family'), '''', '', [rfReplaceAll])
      else if (nm = 'styles') or (nm = 'automatic-styles') or (nm = 'font-face-decls') then
        LoadStyles(c, Prefix);
    end;
    c := c.NextSibling;
  end;
end;

procedure TOdgReader.CollectNamed(N: TDOMNode);
var c: TDOMNode; nm: string;
begin
  if N = nil then Exit;
  c := N.FirstChild;
  while c <> nil do
  begin
    if c is TDOMElement then
    begin
      nm := LName(c);
      if (nm = 'gradient') or (nm = 'hatch') or (nm = 'stroke-dash') or (nm = 'marker') or (nm = 'fill-image') or
         (nm = 'opacity') then
        Named.AddObject(nm + ':' + Attr(c, 'draw:name'), c)
      else if (nm = 'styles') or (nm = 'document-styles') or (nm = 'document-content') or (nm = 'document') then
        CollectNamed(c);
    end;
    c := c.NextSibling;
  end;
end;

function TOdgReader.FindStyle(const Name: string): Integer;
var i: Integer;
begin
  i := StyleIdx.IndexOf(Name);
  if i >= 0 then Result := Integer(PtrInt(StyleIdx.Objects[i])) else Result := -1;
end;

// a property through the parent chain and the default graphic style
function TOdgReader.Prop(const StyleName, Key: string; const Def: string; UseDefault: Boolean): string;
var
  i, guard: Integer;
  nm: string;
begin
  nm := StyleName;
  guard := 0;
  while (nm <> '') and (guard < 32) do
  begin
    i := FindStyle(nm);
    if i < 0 then Break;
    if StyleList[i].Props.IndexOfName(Key) >= 0 then Exit(StyleList[i].Props.Values[Key]);
    nm := StyleList[i].Parent;
    Inc(guard);
  end;
  if UseDefault and (DefaultStyle >= 0) and (StyleList[DefaultStyle].Props.IndexOfName(Key) >= 0) then
    Exit(StyleList[DefaultStyle].Props.Values[Key]);
  Result := Def;
end;

function NamedElem(R: TOdgReader; const Kind, Name: string): TDOMElement;
var i: Integer;
begin
  i := R.Named.IndexOf(Kind + ':' + Name);
  if i >= 0 then Result := TDOMElement(R.Named.Objects[i]) else Result := nil;
end;

// ------------------------------ geometry -----------------------------------

// draw:transform="rotate (a) translate (x y) skewX (s) scale (sx sy) matrix (...)"
function ParseOdfTransform(R: TOdgReader; const T: string): TXVMatrix;
var
  s, fn, args: string;
  p, q: Integer;
  a: TStringArray;
  m: TXVMatrix;
  v: array[0..5] of Double;
  i: Integer;
begin
  Result := TXVMatrix.Identity;
  s := T;
  p := 1;
  while p <= Length(s) do
  begin
    while (p <= Length(s)) and (s[p] in [' ', ',']) do Inc(p);
    q := p;
    while (q <= Length(s)) and (s[q] in ['a'..'z', 'A'..'Z']) do Inc(q);
    fn := LowerCase(Copy(s, p, q - p));
    if fn = '' then Break;
    p := Pos('(', Copy(s, q, MaxInt)) + q;
    q := p;
    while (q <= Length(s)) and (s[q] <> ')') do Inc(q);
    args := Copy(s, p, q - p);
    p := q + 1;
    a := args.Split([' ', ','], TStringSplitOptions.ExcludeEmpty);
    for i := 0 to 5 do
      if i < Length(a) then v[i] := R.Len(a[i]) else v[i] := 0;
    m := TXVMatrix.Identity;
    // ODF rotation is counter-clockwise on the page (y down): negative here
    if fn = 'rotate' then m := TXVMatrix.Rotate(-XVStrToFloat(a[0], 0))
    else if fn = 'translate' then m := TXVMatrix.Translate(v[0], v[1])
    else if fn = 'scale' then
    begin
      if Length(a) >= 2 then m := TXVMatrix.Scale(XVStrToFloat(a[0], 1), XVStrToFloat(a[1], 1))
      else m := TXVMatrix.Scale(XVStrToFloat(a[0], 1), XVStrToFloat(a[0], 1));
    end
    else if fn = 'skewx' then m := TXVMatrix.SkewX(-XVStrToFloat(a[0], 0))
    else if fn = 'skewy' then m := TXVMatrix.SkewY(-XVStrToFloat(a[0], 0))
    else if fn = 'matrix' then
    begin
      if Length(a) >= 6 then m := TXVMatrix.Make(XVStrToFloat(a[0], 1), XVStrToFloat(a[1], 0), XVStrToFloat(a[2], 0),
        XVStrToFloat(a[3], 1), R.Len(a[4]), R.Len(a[5]));
    end;
    // applied in the order written
    Result := XVMul(m, Result);
  end;
end;

function TOdgReader.ShapeMatrix(E: TDOMElement; const Parent: TXVMatrix; out Box: TOdgBox): TXVMatrix;
var t: string;
begin
  Box.W := Len(Attr(E, 'svg:width'));
  Box.H := Len(Attr(E, 'svg:height'));
  t := Attr(E, 'draw:transform');
  if t <> '' then
  begin
    // the shape sits at the origin, the transform places it
    Box.X := 0; Box.Y := 0;
    Result := XVMul(Parent, ParseOdfTransform(Self, t));
  end
  else
  begin
    Box.X := Len(Attr(E, 'svg:x'));
    Box.Y := Len(Attr(E, 'svg:y'));
    Result := Parent;
  end;
end;

// ------------------------------ paint --------------------------------------

function Intensity(C: TXVColor; const S: string): TXVColor;
var v: Double;
begin
  v := XVStrToFloat(StringReplace(S, '%', '', []), 100) / 100;
  if v >= 0.999 then Exit(C);
  Result := XVRGBA(Round(XVColorR(C) * v), Round(XVColorG(C) * v), Round(XVColorB(C) * v), XVColorAlpha(C));
end;

function OdfAngle(const S: string): Double;
var t: string;
begin
  // tenths of a degree without a unit, or "deg" / "rad" / "grad"
  t := LowerCase(Trim(S));
  if Pos('deg', t) > 0 then Result := DegToRad(XVStrToFloat(StringReplace(t, 'deg', '', []), 0))
  else if Pos('grad', t) > 0 then Result := XVStrToFloat(StringReplace(t, 'grad', '', []), 0) * Pi / 200
  else if Pos('rad', t) > 0 then Result := XVStrToFloat(StringReplace(t, 'rad', '', []), 0)
  else Result := DegToRad(XVStrToFloat(t, 0) / 10);
end;

function TOdgReader.MakeFill(const St: string; const P: TXVPath; out Hatch: Boolean): TXVPaint;
var
  f, op, nm, gs: string;
  c, c1, c2: TXVColor;
  ge, fi: TDOMElement;
  g: TXVGradient;
  b: TXVRect;
  a, bord, dx, dy, ln, cx, cy, rad: Double;
  alpha: Double;
  img: TXVImage;
  data: TBytes;
  w, h: Double;
begin
  Result := XVNoPaint;
  Hatch := False;
  f := Prop(St, 'graphic:fill', 'solid');
  op := Prop(St, 'graphic:opacity', '100%');
  alpha := XVStrToFloat(StringReplace(op, '%', '', []), 100) / 100;
  if Prop(St, 'graphic:opacity-name') <> '' then
  begin
    // a transparency gradient: its average opacity
    ge := NamedElem(Self, 'opacity', Prop(St, 'graphic:opacity-name'));
    if ge <> nil then
      alpha := (XVStrToFloat(StringReplace(Attr(ge, 'draw:start'), '%', '', []), 100) +
        XVStrToFloat(StringReplace(Attr(ge, 'draw:end'), '%', '', []), 100)) / 200;
  end;
  if f = 'none' then Exit;
  if f = 'solid' then
  begin
    if not ParseColor(Prop(St, 'graphic:fill-color', '#729fcf'), c) then c := XV_WHITE;
    Exit(XVSolid(XVMulAlpha(c, alpha)));
  end;
  if not P.Bounds(b) then Exit;
  if f = 'gradient' then
  begin
    ge := NamedElem(Self, 'gradient', Prop(St, 'graphic:fill-gradient-name'));
    if ge = nil then Exit(XVSolid(XVMulAlpha($FF808080, alpha)));
    if not ParseColor(Attr(ge, 'draw:start-color'), c1) then c1 := XV_BLACK;
    if not ParseColor(Attr(ge, 'draw:end-color'), c2) then c2 := XV_WHITE;
    c1 := XVMulAlpha(Intensity(c1, Attr(ge, 'draw:start-intensity')), alpha);
    c2 := XVMulAlpha(Intensity(c2, Attr(ge, 'draw:end-intensity')), alpha);
    gs := Attr(ge, 'draw:style');
    a := OdfAngle(Attr(ge, 'draw:angle'));
    bord := EnsureRange(XVStrToFloat(StringReplace(Attr(ge, 'draw:border'), '%', '', []), 0) / 100, 0, 0.99);
    g := Default(TXVGradient);
    g.Matrix := TXVMatrix.Identity;
    w := b.Width; h := b.Height;
    cx := b.Left + w / 2; cy := b.Top + h / 2;
    if (gs = 'linear') or (gs = 'axial') then
    begin
      g.Kind := gkLinear;
      // angle 0: from top to bottom; it turns counter-clockwise
      dx := Sin(a); dy := Cos(a);
      ln := Abs(w * dx) + Abs(h * dy);
      g.X1 := cx - dx * ln / 2; g.Y1 := cy - dy * ln / 2;
      g.X2 := cx + dx * ln / 2; g.Y2 := cy + dy * ln / 2;
      if gs = 'linear' then
      begin
        SetLength(g.Stops, 3);
        g.Stops[0].Offset := 0; g.Stops[0].Color := c1;
        g.Stops[1].Offset := bord; g.Stops[1].Color := c1;
        g.Stops[2].Offset := 1; g.Stops[2].Color := c2;
      end
      else
      begin
        SetLength(g.Stops, 5);
        g.Stops[0].Offset := 0; g.Stops[0].Color := c1;
        g.Stops[1].Offset := bord / 2; g.Stops[1].Color := c1;
        g.Stops[2].Offset := 0.5; g.Stops[2].Color := c2;
        g.Stops[3].Offset := 1 - bord / 2; g.Stops[3].Color := c1;
        g.Stops[4].Offset := 1; g.Stops[4].Color := c1;
      end;
    end
    else
    begin
      g.Kind := gkRadial;
      cx := b.Left + w * XVStrToFloat(StringReplace(Attr(ge, 'draw:cx'), '%', '', []), 50) / 100;
      cy := b.Top + h * XVStrToFloat(StringReplace(Attr(ge, 'draw:cy'), '%', '', []), 50) / 100;
      g.CX := cx; g.CY := cy; g.FX := cx; g.FY := cy;
      if (gs = 'ellipsoid') or (gs = 'rectangular') then
      begin
        // the circle stretched to the box proportions
        g.R := Sqrt(2) / 2;
        g.CX := 0; g.CY := 0; g.FX := 0; g.FY := 0;
        g.Matrix := TXVMatrix.Make(w, 0, 0, h, cx, cy);
      end
      else
      begin
        rad := Hypot(w, h) / 2;
        g.R := rad;
      end;
      // the start colour outside, the end colour at the centre
      SetLength(g.Stops, 3);
      g.Stops[0].Offset := 0; g.Stops[0].Color := c2;
      g.Stops[1].Offset := 1 - bord; g.Stops[1].Color := c1;
      g.Stops[2].Offset := 1; g.Stops[2].Color := c1;
    end;
    Exit(XVGradientPaint(Doc.AddGradient(g), XVLerpColor(c1, c2, 0.5)));
  end;
  if f = 'hatch' then
  begin
    Hatch := True;
    // the background under the hatch lines
    if Prop(St, 'graphic:fill-hatch-solid') = 'true' then
    begin
      if ParseColor(Prop(St, 'graphic:fill-color', '#ffffff'), c) then Exit(XVSolid(XVMulAlpha(c, alpha)));
    end;
    Exit;
  end;
  if f = 'bitmap' then
  begin
    fi := NamedElem(Self, 'fill-image', Prop(St, 'graphic:fill-image-name'));
    if fi <> nil then
    begin
      nm := Attr(fi, 'xlink:href');
      data := XVZipReadName(Zip, ZipList, nm);
      if (Length(data) > 0) and XVDecodeImage(data, img) then
      begin
        if Prop(St, 'graphic:repeat', 'repeat') = 'stretch' then
          Exit(XVPatternPaint(Doc.AddPattern(Doc.AddImageData(img), TXVMatrix.Make(w / Max(1, img.W), 0, 0,
            h / Max(1, img.H), b.Left, b.Top)), XVImageAverage(img)))
        else
          Exit(XVPatternPaint(Doc.AddPattern(Doc.AddImageData(img), TXVMatrix.Translate(b.Left, b.Top)),
            XVImageAverage(img)));
      end;
    end;
    Exit(XVSolid(XVMulAlpha($FF808080, alpha)));
  end;
end;

// hatch lines (single, double, triple) clipped to the shape
procedure TOdgReader.HatchFill(const St: string; const P: TXVPath);
var
  he: TDOMElement;
  c: TXVColor;
  dist, a, a2, cx, cy, r, t, dx, dy, nx, ny: Double;
  b: TXVRect;
  lines: TXVPath;
  k, fam, n: Integer;
  style: string;
begin
  he := NamedElem(Self, 'hatch', Prop(St, 'graphic:fill-hatch-name'));
  if (he = nil) or not P.Bounds(b) then Exit;
  if not ParseColor(Attr(he, 'draw:color'), c) then c := XV_BLACK;
  dist := Max(Len(Attr(he, 'draw:distance')), 1);
  a := OdfAngle(Attr(he, 'draw:rotation'));
  style := Attr(he, 'draw:style');
  cx := (b.Left + b.Right) / 2; cy := (b.Top + b.Bottom) / 2;
  r := Hypot(b.Width, b.Height) / 2 + dist;
  lines := Default(TXVPath);
  lines.Clear;
  if style = 'triple' then n := 3 else if style = 'double' then n := 2 else n := 1;
  for fam := 0 to n - 1 do
  begin
    case fam of
      1: a2 := a + Pi / 2;
      2: a2 := a + Pi / 4;
    else
      a2 := a;
    end;
    // lines along (cos, -sin) on the page
    dx := Cos(a2); dy := -Sin(a2);
    nx := -dy; ny := dx;
    k := Ceil(r / dist);
    if k > 5000 then Exit;
    for k := -Ceil(r / dist) to Ceil(r / dist) do
    begin
      t := k * dist;
      lines.MoveTo(cx + nx * t - dx * r, cy + ny * t - dy * r);
      lines.LineTo(cx + nx * t + dx * r, cy + ny * t + dy * r);
    end;
  end;
  Doc.BeginGroup(Doc.AddClip(P, frEvenOdd), 1);
  Doc.AddPath(lines, XVNoPaint, XVStroke(c, 0), frNonZero);
  Doc.EndGroup;
end;

function TOdgReader.MakeStroke(const St: string; const M: TXVMatrix): TXVStroke;
var
  s, j, cap: string;
  c: TXVColor;
  w, d1, d2, dl1, dl2, dd: Double;
  de: TDOMElement;
  n1, n2, i: Integer;
  alpha: Double;
begin
  Result := XVNoStroke;
  s := Prop(St, 'graphic:stroke', 'solid');
  if s = 'none' then Exit;
  if not ParseColor(Prop(St, 'graphic:stroke-color', '#3465a4'), c) then c := XV_BLACK;
  alpha := XVStrToFloat(StringReplace(Prop(St, 'graphic:stroke-opacity', '100%'), '%', '', []), 100) / 100;
  w := Len(Prop(St, 'graphic:stroke-width', '0'));
  Result := XVStroke(XVMulAlpha(c, alpha), w * M.ScaleFactor);
  j := Prop(St, 'graphic:stroke-linejoin', 'round');
  if j = 'miter' then Result.Join := ljMiter
  else if j = 'bevel' then Result.Join := ljBevel
  else Result.Join := ljRound;
  cap := Prop(St, 'graphic:stroke-linecap', 'butt');
  if cap = 'round' then Result.Cap := lcRound
  else if cap = 'square' then Result.Cap := lcSquare
  else Result.Cap := lcButt;
  if s = 'dash' then
  begin
    de := NamedElem(Self, 'stroke-dash', Prop(St, 'graphic:stroke-dash'));
    if de <> nil then
    begin
      // lengths may be relative to the line width
      w := Max(Result.Width, 1 / Max(M.ScaleFactor, 1e-9));
      n1 := StrToIntDef(Attr(de, 'draw:dots1'), 1);
      n2 := StrToIntDef(Attr(de, 'draw:dots2'), 0);
      dl1 := Len(Attr(de, 'draw:dots1-length'), w * 100, w);
      dl2 := Len(Attr(de, 'draw:dots2-length'), w * 100, w);
      dd := Len(Attr(de, 'draw:distance'), w * 100, w);
      if Pos('%', Attr(de, 'draw:dots1-length')) = 0 then dl1 := dl1 * M.ScaleFactor;
      if Pos('%', Attr(de, 'draw:dots2-length')) = 0 then dl2 := dl2 * M.ScaleFactor;
      if Pos('%', Attr(de, 'draw:distance')) = 0 then dd := dd * M.ScaleFactor;
      if dl1 <= 0 then dl1 := w;
      if dl2 <= 0 then dl2 := w;
      if dd <= 0 then dd := w;
      SetLength(Result.Dashes, 2 * (n1 + n2));
      for i := 0 to n1 - 1 do begin Result.Dashes[2 * i] := dl1; Result.Dashes[2 * i + 1] := dd; end;
      for i := 0 to n2 - 1 do begin Result.Dashes[2 * (n1 + i)] := dl2; Result.Dashes[2 * (n1 + i) + 1] := dd; end;
      if Length(Result.Dashes) < 2 then Result.Dashes := nil;
      if Attr(de, 'draw:style') = 'round' then Result.Cap := lcRound;
    end
    else Result.Dashes := [Len('0.05cm') * M.ScaleFactor, Len('0.05cm') * M.ScaleFactor];   // the default fine dash
  end;
  if d1 = 0 then ;
  if d2 = 0 then ;
end;

// arrow heads at the ends of open paths
procedure TOdgReader.Markers(const St: string; const P: TXVPath; const M: TXVMatrix);
var
  k: Integer;
  nm, vb: string;
  me: TDOMElement;
  w, ang, vx, vy, vw, vh: Double;
  mp: TXVPath;
  a: TStringArray;
  tip, prev: TXVPoint;
  c: TXVColor;
  t: TXVMatrix;
  last: Integer;
begin
  if P.NPt < 2 then Exit;
  for k := 0 to 1 do
  begin
    if k = 0 then nm := Prop(St, 'graphic:marker-start') else nm := Prop(St, 'graphic:marker-end');
    if nm = '' then Continue;
    me := NamedElem(Self, 'marker', nm);
    if me = nil then Continue;
    if k = 0 then w := Len(Prop(St, 'graphic:marker-start-width', '0.2cm')) else w := Len(Prop(St, 'graphic:marker-end-width', '0.2cm'));
    w := w * M.ScaleFactor;
    vb := Attr(me, 'svg:viewBox');
    a := vb.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Length(a) < 4 then Continue;
    vx := XVStrToFloat(a[0]); vy := XVStrToFloat(a[1]); vw := XVStrToFloat(a[2]); vh := XVStrToFloat(a[3]);
    if (vw <= 0) or (vh <= 0) then Continue;
    mp := Default(TXVPath);
    mp.Clear;
    XVParseSvgPathData(Attr(me, 'svg:d'), mp);
    // the tip of the marker (top centre of its box) at the line end, pointing outwards
    last := P.NPt - 1;
    if k = 0 then begin tip := P.Pts[0]; prev := P.Pts[1]; end
    else begin tip := P.Pts[last]; prev := P.Pts[last - 1]; end;
    ang := ArcTan2(tip.Y - prev.Y, tip.X - prev.X);
    t := XVMul(TXVMatrix.Translate(tip.X, tip.Y), TXVMatrix.Rotate(ang + Pi / 2));
    t := XVMul(t, TXVMatrix.Scale(w / vw, w / vw));
    t := XVMul(t, TXVMatrix.Translate(-(vx + vw / 2), -vy));
    mp.Transform(t);
    if not ParseColor(Prop(St, 'graphic:stroke-color', '#3465a4'), c) then c := XV_BLACK;
    Doc.AddPath(mp, XVSolid(c), XVNoStroke, frNonZero);
  end;
end;

procedure TOdgReader.Emit(E: TDOMElement; const St: string; const LocalPath: TXVPath; const M: TXVMatrix; Closed: Boolean;
  Rule: TXVFillRule);
var
  p, sp: TXVPath;
  fill: TXVPaint;
  stk: TXVStroke;
  hatch: Boolean;
  sx, sy: Double;
  sc: TXVColor;
begin
  p := LocalPath.Copy;
  p.Transform(M);
  if Closed then fill := MakeFill(St, p, hatch) else begin fill := XVNoPaint; hatch := False; end;
  stk := MakeStroke(St, M);
  // shadow: an offset copy below
  if Prop(St, 'graphic:shadow') = 'visible' then
  begin
    sx := Len(Prop(St, 'graphic:shadow-offset-x', '0.2cm')); sy := Len(Prop(St, 'graphic:shadow-offset-y', '0.2cm'));
    if not ParseColor(Prop(St, 'graphic:shadow-color', '#808080'), sc) then sc := $FF808080;
    sc := XVMulAlpha(sc, XVStrToFloat(StringReplace(Prop(St, 'graphic:shadow-opacity', '100%'), '%', '', []), 100) / 100);
    sp := p.Copy;
    sp.Transform(TXVMatrix.Translate(sx, sy));
    if (fill.Kind <> pkNone) or hatch then Doc.AddPath(sp, XVSolid(sc), XVNoStroke, Rule)
    else if stk.Paint.Kind <> pkNone then
    begin
      stk.Paint := XVSolid(sc);
      Doc.AddPath(sp, XVNoPaint, stk, Rule);
      stk := MakeStroke(St, M);
    end;
  end;
  if (fill.Kind <> pkNone) then Doc.AddPath(p, fill, XVNoStroke, Rule);
  if hatch then HatchFill(St, p);
  if stk.Paint.Kind <> pkNone then Doc.AddPath(p, XVNoPaint, stk, Rule);
  if not Closed then Markers(St, p, M);
end;

// ------------------------------ text ---------------------------------------

procedure TOdgReader.ShapeText(E: TDOMElement; const St: string; const Box: TOdgBox; const M: TXVMatrix; TextBox: Boolean);
type
  TRun = record
    S: string;
    F: TXVFont;
    C: TXVColor;
  end;
  TLine = record
    Runs: array of TRun;
    Align: TXVTextAnchor;
    Size: Double;
  end;
var
  lines: array of TLine;
  container: TDOMNode;
  c: TDOMNode;
  i, j, idx, first: Integer;
  total, y, x, padL, padR, padT, padB, lh: Double;
  va, ha: string;
  tm: TXVMatrix;

  function StyleFont(const TS: string; const Base: TXVFont; out C: TXVColor; Def: Boolean = False): TXVFont;
  var v, fn: string;
  begin
    Result := Base;
    v := Prop(TS, 'text:font-size', '', Def);
    if v <> '' then Result.Size := Len(v, Base.Size, Base.Size);
    fn := Prop(TS, 'text:font-name', '', Def);
    if fn <> '' then
    begin
      if Fonts.IndexOfName(fn) >= 0 then Result.Family := Fonts.Values[fn] else Result.Family := fn;
    end
    else if Prop(TS, 'text:font-family', '', Def) <> '' then Result.Family := StringReplace(Prop(TS, 'text:font-family', '', Def), '''', '', [rfReplaceAll]);
    v := Prop(TS, 'text:font-weight', '', Def);
    if (v = 'bold') or (StrToIntDef(v, 400) >= 600) then Result.Weight := 700
    else if v <> '' then Result.Weight := 400;
    v := Prop(TS, 'text:font-style', '', Def);
    if v <> '' then Result.Italic := (v = 'italic') or (v = 'oblique');
    if (Prop(TS, 'text:text-underline-style', '', Def) <> '') and (Prop(TS, 'text:text-underline-style', '', Def) <> 'none') then Result.Underline := True;
    if (Prop(TS, 'text:text-line-through-style', '', Def) <> '') and (Prop(TS, 'text:text-line-through-style', '', Def) <> 'none') then Result.Strike := True;
    if not ParseColor(Prop(TS, 'text:color', '#000000', Def), C) then C := XV_BLACK;
  end;

  procedure AddRun(var L: TLine; const S: string; const F: TXVFont; Col: TXVColor);
  var n: Integer;
  begin
    if S = '' then Exit;
    n := Length(L.Runs);
    SetLength(L.Runs, n + 1);
    L.Runs[n].S := S;
    L.Runs[n].F := F;
    L.Runs[n].C := Col;
    L.Size := Max(L.Size, F.Size);
  end;

  procedure Walk(N: TDOMNode; var L: TLine; const F: TXVFont; Col: TXVColor);
  var
    k: TDOMNode;
    nm: string;
    f2: TXVFont;
    c2: TXVColor;
    cnt, q: Integer;
    s: string;
  begin
    k := N.FirstChild;
    while k <> nil do
    begin
      if k.NodeType = TEXT_NODE then AddRun(L, UTF8Encode(k.NodeValue), F, Col)
      else if k is TDOMElement then
      begin
        nm := LName(k);
        if nm = 'span' then
        begin
          f2 := StyleFont(Attr(k, 'text:style-name'), F, c2);
          if Prop(Attr(k, 'text:style-name'), 'color') = '' then c2 := Col;
          Walk(k, L, f2, c2);
        end
        else if nm = 's' then
        begin
          cnt := StrToIntDef(Attr(k, 'text:c'), 1);
          s := '';
          for q := 1 to cnt do s := s + ' ';
          AddRun(L, s, F, Col);
        end
        else if nm = 'tab' then AddRun(L, '    ', F, Col)
        else if nm = 'line-break' then
        begin
          SetLength(lines, Length(lines) + 1);
          lines[High(lines)] := L;
          L.Runs := nil;
          L.Size := F.Size;
        end
        else if (nm = 'a') or (nm = 'span') then Walk(k, L, F, Col);
      end;
      k := k.NextSibling;
    end;
  end;

  procedure Para(N: TDOMNode; const BaseF: TXVFont; BaseC: TXVColor);
  var
    L: TLine;
    f: TXVFont;
    col: TXVColor;
    ps, al: string;
  begin
    ps := Attr(N, 'text:style-name');
    f := StyleFont(ps, BaseF, col);
    if Prop(ps, 'text:color', '', False) = '' then col := BaseC;
    L.Runs := nil;
    L.Size := f.Size;
    al := Prop(ps, 'paragraph:text-align', '', False);
    if (al = 'center') then L.Align := taMiddle
    else if (al = 'end') or (al = 'right') then L.Align := taEnd
    else if (al = 'start') or (al = 'left') or (al = 'justify') then L.Align := taStart
    else if TextBox then L.Align := taStart
    else L.Align := taMiddle;
    Walk(N, L, f, col);
    SetLength(lines, Length(lines) + 1);
    lines[High(lines)] := L;
  end;

  procedure Collect(N: TDOMNode; const BaseF: TXVFont; BaseC: TXVColor);
  var k: TDOMNode;
  begin
    k := N.FirstChild;
    while k <> nil do
    begin
      if k is TDOMElement then
      begin
        if (LName(k) = 'p') or (LName(k) = 'h') then Para(k, BaseF, BaseC)
        else if (LName(k) = 'list') or (LName(k) = 'list-item') then Collect(k, BaseF, BaseC);
      end;
      k := k.NextSibling;
    end;
  end;

var
  base: TXVFont;
  basec: TXVColor;
begin
  container := E;
  // frames keep the text in a text box
  c := E.FirstChild;
  while c <> nil do
  begin
    if (c is TDOMElement) and (LName(c) = 'text-box') then container := c;
    c := c.NextSibling;
  end;
  base := XVDefaultFont;
  base.Size := Len('18pt');
  base := StyleFont(St, base, basec, True);
  base := StyleFont(Attr(E, 'draw:text-style-name'), base, basec);
  lines := nil;
  Collect(container, base, basec);
  if Length(lines) = 0 then Exit;
  // drop empty trailing lines; nothing to draw when all are empty
  total := 0;
  first := 0;
  for i := 0 to High(lines) do
    for j := 0 to High(lines[i].Runs) do
      if Trim(lines[i].Runs[j].S) <> '' then Inc(first);
  if first = 0 then Exit;
  for i := 0 to High(lines) do total := total + lines[i].Size * 1.17;
  padL := Len(Prop(St, 'graphic:padding-left', '0.25cm')); padR := Len(Prop(St, 'graphic:padding-right', '0.25cm'));
  padT := Len(Prop(St, 'graphic:padding-top', '0.125cm')); padB := Len(Prop(St, 'graphic:padding-bottom', '0.125cm'));
  va := Prop(St, 'graphic:textarea-vertical-align');
  ha := Prop(St, 'graphic:textarea-horizontal-align');
  if va = '' then
  begin
    if TextBox then va := 'top' else va := 'middle';
  end;
  if va = 'top' then y := Box.Y + padT
  else if va = 'bottom' then y := Box.Y + Box.H - padB - total
  else y := Box.Y + (Box.H - total) / 2;
  for i := 0 to High(lines) do
  begin
    lh := lines[i].Size * 1.17;
    y := y + lines[i].Size * 0.93;
    case lines[i].Align of
      taMiddle: x := Box.X + Box.W / 2;
      taEnd: x := Box.X + Box.W - padR;
    else
      x := Box.X + padL;
    end;
    if (ha = 'center') and not TextBox then x := Box.X + Box.W / 2;
    first := -1;
    for j := 0 to High(lines[i].Runs) do
    begin
      tm := XVMul(M, TXVMatrix.Translate(x, y));
      if first >= 0 then begin tm.E := 0; tm.F := 0; end;
      idx := Doc.AddText(lines[i].Runs[j].S, lines[i].Runs[j].F, tm, XVSolid(lines[i].Runs[j].C), lines[i].Align);
      if (ha = 'center') and not TextBox then Doc.Elements[idx].Anchor := taMiddle;
      Doc.Elements[idx].Continued := first >= 0;
      if first < 0 then first := idx;
    end;
    y := y + lh - lines[i].Size * 0.93;
  end;
end;

// ------------------------------ custom shapes ------------------------------

type
  TFormulaCtx = record
    R: TOdgReader;
    Eqs: TStringArray;
    Vals: TXVDoubles;
    Done: array of Byte;           // 0 not evaluated, 1 in progress, 2 done
    Mods: TXVDoubles;
    VB: TXVRect;
    W, H: Double;                  // shape size (logical)
  end;

function EvalFormula(var C: TFormulaCtx; const S: string): Double; forward;

function EqValue(var C: TFormulaCtx; I: Integer): Double;
begin
  if (I < 0) or (I > High(C.Eqs)) then Exit(0);
  if C.Done[I] = 2 then Exit(C.Vals[I]);
  if C.Done[I] = 1 then Exit(0);          // a cycle
  C.Done[I] := 1;
  C.Vals[I] := EvalFormula(C, C.Eqs[I]);
  C.Done[I] := 2;
  Result := C.Vals[I];
end;

// recursive descent: expression, terms, factors, functions
function EvalFormula(var C: TFormulaCtx; const S: string): Double;
var p: Integer;

  procedure Ws;
  begin
    while (p <= Length(S)) and (S[p] in [' ', #9]) do Inc(p);
  end;

  function Expr: Double; forward;

  function Ident: string;
  begin
    Result := '';
    while (p <= Length(S)) and (S[p] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
    begin
      Result := Result + S[p];
      Inc(p);
    end;
  end;

  function Factor: Double;
  var
    id, num: string;
    a, b, cc: Double;
    st: Integer;
  begin
    Ws;
    Result := 0;
    if p > Length(S) then Exit;
    if S[p] = '-' then begin Inc(p); Exit(-Factor); end;
    if S[p] = '+' then begin Inc(p); Exit(Factor); end;
    if S[p] = '(' then
    begin
      Inc(p);
      Result := Expr;
      Ws;
      if (p <= Length(S)) and (S[p] = ')') then Inc(p);
      Exit;
    end;
    if S[p] = '?' then
    begin
      Inc(p);
      id := Ident;                 // fN
      Exit(EqValue(C, StrToIntDef(Copy(id, 2, MaxInt), -1)));
    end;
    if S[p] = '$' then
    begin
      Inc(p);
      st := StrToIntDef(Ident, 0);
      if (st >= 0) and (st <= High(C.Mods)) then Exit(C.Mods[st]);
      Exit(0);
    end;
    if S[p] in ['0'..'9', '.'] then
    begin
      num := '';
      while (p <= Length(S)) and (S[p] in ['0'..'9', '.', 'e', 'E']) do
      begin
        num := num + S[p];
        Inc(p);
      end;
      Exit(XVStrToFloat(num, 0));
    end;
    id := LowerCase(Ident);
    Ws;
    if (p <= Length(S)) and (S[p] = '(') then
    begin
      Inc(p);
      a := Expr; b := 0; cc := 0;
      Ws;
      if (p <= Length(S)) and (S[p] = ',') then begin Inc(p); b := Expr; Ws; end;
      if (p <= Length(S)) and (S[p] = ',') then begin Inc(p); cc := Expr; Ws; end;
      if (p <= Length(S)) and (S[p] = ')') then Inc(p);
      if id = 'sin' then Exit(Sin(a));
      if id = 'cos' then Exit(Cos(a));
      if id = 'tan' then Exit(Tan(a));
      if id = 'atan' then Exit(ArcTan(a));
      if id = 'atan2' then Exit(ArcTan2(a, b));
      if id = 'sqrt' then Exit(Sqrt(Abs(a)));
      if id = 'abs' then Exit(Abs(a));
      if id = 'min' then Exit(Min(a, b));
      if id = 'max' then Exit(Max(a, b));
      if id = 'if' then begin if a > 0 then Exit(b) else Exit(cc); end;
      Exit(a);
    end;
    if id = 'pi' then Exit(Pi);
    if id = 'left' then Exit(C.VB.Left);
    if id = 'top' then Exit(C.VB.Top);
    if id = 'right' then Exit(C.VB.Right);
    if id = 'bottom' then Exit(C.VB.Bottom);
    if id = 'width' then Exit(C.VB.Width);
    if id = 'height' then Exit(C.VB.Height);
    if id = 'logwidth' then Exit(C.W * 2540 / 96);
    if id = 'logheight' then Exit(C.H * 2540 / 96);
    if (id = 'xstretch') or (id = 'ystretch') then Exit(0);
    if (id = 'hasstroke') or (id = 'hasfill') then Exit(1);
    Result := 0;
  end;

  function Term: Double;
  var op: Char; b: Double;
  begin
    Result := Factor;
    repeat
      Ws;
      if (p <= Length(S)) and (S[p] in ['*', '/']) then
      begin
        op := S[p];
        Inc(p);
        b := Factor;
        if op = '*' then Result := Result * b
        else if Abs(b) > 1e-300 then Result := Result / b
        else Result := 0;
      end
      else Break;
    until False;
  end;

  function Expr: Double;
  var op: Char;
  begin
    Result := Term;
    repeat
      Ws;
      if (p <= Length(S)) and (S[p] in ['+', '-']) then
      begin
        op := S[p];
        Inc(p);
        if op = '+' then Result := Result + Term else Result := Result - Term;
      end
      else Break;
    until False;
  end;

begin
  p := 1;
  Result := Expr;
  if IsNan(Result) or IsInfinite(Result) then Result := 0;
end;

// predefined shapes written without a path (other producers)
function PresetPath(const Typ: string): string;
begin
  if Typ = 'rectangle' then Result := 'M 0 0 L 21600 0 21600 21600 0 21600 Z N'
  else if Typ = 'ellipse' then Result := 'U 10800 10800 10800 10800 0 360 Z N'
  else if Typ = 'diamond' then Result := 'M 10800 0 L 21600 10800 10800 21600 0 10800 Z N'
  else if Typ = 'isosceles-triangle' then Result := 'M 10800 0 L 21600 21600 0 21600 Z N'
  else if Typ = 'right-triangle' then Result := 'M 0 0 L 21600 21600 0 21600 Z N'
  else if Typ = 'parallelogram' then Result := 'M 5400 0 L 21600 0 16200 21600 0 21600 Z N'
  else if Typ = 'trapezoid' then Result := 'M 0 0 L 21600 0 16200 21600 5400 21600 Z N'
  else if Typ = 'hexagon' then Result := 'M 5400 0 L 16200 0 21600 10800 16200 21600 5400 21600 0 10800 Z N'
  else if Typ = 'octagon' then Result := 'M 6326 0 L 15274 0 21600 6326 21600 15274 15274 21600 6326 21600 0 15274 0 6326 Z N'
  else if Typ = 'pentagon' then Result := 'M 10800 0 L 0 8260 4230 21600 17370 21600 21600 8260 Z N'
  else if Typ = 'cross' then Result := 'M 5400 0 L 16200 0 16200 5400 21600 5400 21600 16200 16200 16200 16200 21600 5400 21600 5400 16200 0 16200 0 5400 5400 5400 Z N'
  else if Typ = 'star5' then Result := 'M 10797 0 L 8278 8256 0 8256 6722 13405 4198 21600 10797 16580 17401 21600 14878 13405 21600 8256 13321 8256 Z N'
  else if Typ = 'right-arrow' then Result := 'M 0 5400 L 16200 5400 16200 0 21600 10800 16200 21600 16200 16200 0 16200 Z N'
  else if Typ = 'left-arrow' then Result := 'M 21600 5400 L 5400 5400 5400 0 0 10800 5400 21600 5400 16200 21600 16200 Z N'
  else if Typ = 'up-arrow' then Result := 'M 5400 21600 L 5400 5400 0 5400 10800 0 21600 5400 16200 5400 16200 21600 Z N'
  else if Typ = 'down-arrow' then Result := 'M 5400 0 L 5400 16200 0 16200 10800 21600 21600 16200 16200 16200 16200 0 Z N'
  else if Typ = 'round-rectangle' then Result := 'M 3600 0 X 0 3600 L 0 18000 Y 3600 21600 L 18000 21600 X 21600 18000 L 21600 3600 Y 18000 0 Z N'
  else if Typ = 'cloud' then
    Result := 'M 3900 14370 C 1800 14370 0 12570 0 10470 0 8370 1800 6570 3900 6570 4500 3150 7800 1170 11100 2400 ' +
      '12900 450 16200 900 17400 3150 19800 3450 21600 5850 21000 8250 21900 10050 21600 12900 19800 14070 ' +
      '19500 17700 16200 19800 13200 18300 11400 21000 7800 21000 6600 18600 4200 18900 2700 16800 3900 14370 Z N'
  else Result := '';
end;

function TOdgReader.CustomShape(E: TDOMElement; const Box: TOdgBox; out Parts: TArray<TXVPath>;
  out NoFill, NoStroke: TArray<Boolean>): Boolean;
var
  ge: TDOMElement;
  c: TDOMNode;
  ctx: TFormulaCtx;
  vb, path, typ, tok, mods: string;
  a: TStringArray;
  toks: TStringArray;
  i, n, k: Integer;
  cmd: Char;
  P: TXVPath;
  nf, ns: Boolean;
  sx, sy: Double;
  mirH, mirV: Boolean;
  cur: TXVPoint;

  function Num: Double;
  var t: string;
  begin
    if i > High(toks) then Exit(0);
    t := toks[i];
    Inc(i);
    if t = '' then Exit(0);
    if t[1] = '?' then Result := EqValue(ctx, StrToIntDef(Copy(t, 3, MaxInt), -1))
    else if t[1] = '$' then
    begin
      k := StrToIntDef(Copy(t, 2, MaxInt), 0);
      if (k >= 0) and (k <= High(ctx.Mods)) then Result := ctx.Mods[k] else Result := 0;
    end
    else if t[1] in ['0'..'9', '-', '+', '.'] then Result := XVStrToFloat(t, 0)
    else Result := EvalFormula(ctx, t);
  end;

  function IsNum: Boolean;
  begin
    Result := (i <= High(toks)) and (toks[i] <> '') and not ((Length(toks[i]) = 1) and (toks[i][1] in ['A'..'Z']));
  end;

  procedure MapXY(x, y: Double; out ox, oy: Double);
  begin
    ox := Box.X + (x - ctx.VB.Left) * sx;
    oy := Box.Y + (y - ctx.VB.Top) * sy;
    if mirH then ox := 2 * Box.X + Box.W - ox;
    if mirV then oy := 2 * Box.Y + Box.H - oy;
  end;

  procedure Flush;
  var n2: Integer;
  begin
    if P.NCmd > 0 then
    begin
      n2 := Length(Parts);
      SetLength(Parts, n2 + 1); SetLength(NoFill, n2 + 1); SetLength(NoStroke, n2 + 1);
      Parts[n2] := P.Copy;
      NoFill[n2] := nf;
      NoStroke[n2] := ns;
    end;
    P.Clear;
    nf := False; ns := False;
  end;

  // an elliptic arc in logical space: centre, radii, start and sweep (radians, y down)
  procedure LArc(cx, cy, rx, ry, t0, sw: Double; Lead: Integer);
  var j, m: Integer; t, x, y: Double;
  begin
    m := Max(4, Ceil(Abs(sw) / (Pi / 16)));
    for j := 0 to m do
    begin
      t := t0 + sw * j / m;
      MapXY(cx + rx * Cos(t), cy + ry * Sin(t), x, y);
      if (j = 0) and (Lead = 1) then P.MoveTo(x, y)
      else P.LineTo(x, y);
    end;
    cur.X := cx + rx * Cos(t0 + sw); cur.Y := cy + ry * Sin(t0 + sw);
  end;

  // A / B / W / V: the arc of the ellipse in the box (x1 y1 x2 y2) from the
  // direction of (x3, y3) to the direction of (x4, y4)
  procedure BoxArc(Clockwise, Lead: Boolean);
  var x1, y1, x2, y2, x3, y3, x4, y4, cx, cy, rx, ry, t0, t1, sw: Double;
  begin
    x1 := Num; y1 := Num; x2 := Num; y2 := Num; x3 := Num; y3 := Num; x4 := Num; y4 := Num;
    cx := (x1 + x2) / 2; cy := (y1 + y2) / 2;
    rx := Abs(x2 - x1) / 2; ry := Abs(y2 - y1) / 2;
    if (rx < 1e-9) or (ry < 1e-9) then Exit;
    t0 := ArcTan2((y3 - cy) / ry, (x3 - cx) / rx);
    t1 := ArcTan2((y4 - cy) / ry, (x4 - cx) / rx);
    sw := t1 - t0;
    // counter-clockwise as seen (y down): decreasing angles
    if Clockwise then begin while sw <= 0 do sw := sw + 2 * Pi; end
    else begin while sw >= 0 do sw := sw - 2 * Pi; end;
    if Lead then LArc(cx, cy, rx, ry, t0, sw, 1) else LArc(cx, cy, rx, ry, t0, sw, 2);
  end;

  // T / U: centre, radii, start and end angle in degrees
  procedure AngleEllipse(Start: Boolean);
  var cx, cy, rx, ry, t0, t1, sw: Double;
  begin
    cx := Num; cy := Num; rx := Num; ry := Num; t0 := Num; t1 := Num;
    sw := t1 - t0;
    if Abs(sw) >= 360 then sw := 360;
    if Start then LArc(cx, cy, rx, ry, DegToRad(-t0), -DegToRad(sw), 1)
    else LArc(cx, cy, rx, ry, DegToRad(-t0), -DegToRad(sw), 2);
  end;

  // X / Y: a quarter ellipse to (x, y), leaving horizontally (X) or vertically (Y)
  procedure Quadrant(Horizontal: Boolean);
  var x, y, ox, oy, k_, c1x, c1y, c2x, c2y, ex, ey: Double;
  begin
    x := Num; y := Num;
    k_ := 0.5522847498;
    if Horizontal then
    begin
      c1x := cur.X + (x - cur.X) * k_; c1y := cur.Y;
      c2x := x; c2y := y - (y - cur.Y) * k_;
    end
    else
    begin
      c1x := cur.X; c1y := cur.Y + (y - cur.Y) * k_;
      c2x := x - (x - cur.X) * k_; c2y := y;
    end;
    MapXY(c1x, c1y, ox, oy);
    MapXY(c2x, c2y, c1x, c1y);
    MapXY(x, y, ex, ey);
    P.CubicTo(ox, oy, c1x, c1y, ex, ey);
    cur.X := x; cur.Y := y;
  end;

var
  x, y, x1, y1, x2, y2, ox, oy, ox1, oy1, ox2, oy2, wr, hr, st, swa, cx, cy: Double;
  horiz: Boolean;
begin
  Result := False;
  Parts := nil; NoFill := nil; NoStroke := nil;
  ge := nil;
  c := E.FirstChild;
  while c <> nil do
  begin
    if (c is TDOMElement) and (LName(c) = 'enhanced-geometry') then ge := TDOMElement(c);
    c := c.NextSibling;
  end;
  if ge = nil then Exit;
  ctx.R := Self;
  vb := Attr(ge, 'svg:viewBox');
  if vb = '' then vb := '0 0 21600 21600';
  a := vb.Split([' '], TStringSplitOptions.ExcludeEmpty);
  if Length(a) < 4 then Exit;
  ctx.VB := XVRect(XVStrToFloat(a[0]), XVStrToFloat(a[1]), XVStrToFloat(a[0]) + XVStrToFloat(a[2]),
    XVStrToFloat(a[1]) + XVStrToFloat(a[3]));
  ctx.W := Box.W; ctx.H := Box.H;
  // equations and modifiers
  ctx.Eqs := nil;
  c := ge.FirstChild;
  while c <> nil do
  begin
    if (c is TDOMElement) and (LName(c) = 'equation') then
    begin
      n := StrToIntDef(Copy(Attr(c, 'draw:name'), 2, MaxInt), -1);
      if n >= 0 then
      begin
        if n > High(ctx.Eqs) then SetLength(ctx.Eqs, n + 1);
        ctx.Eqs[n] := Attr(c, 'draw:formula');
      end;
    end;
    c := c.NextSibling;
  end;
  SetLength(ctx.Vals, Length(ctx.Eqs));
  SetLength(ctx.Done, Length(ctx.Eqs));
  for n := 0 to High(ctx.Done) do ctx.Done[n] := 0;
  mods := Attr(ge, 'draw:modifiers');
  a := mods.Split([' '], TStringSplitOptions.ExcludeEmpty);
  SetLength(ctx.Mods, Length(a));
  for n := 0 to High(a) do ctx.Mods[n] := XVStrToFloat(a[n], 0);
  typ := Attr(ge, 'draw:type');
  path := Attr(ge, 'draw:enhanced-path');
  if path = '' then path := PresetPath(typ);
  if path = '' then
  begin
    // an unknown preset: its box
    path := 'M 0 0 L 21600 0 21600 21600 0 21600 Z N';
    ctx.VB := XVRect(0, 0, 21600, 21600);
  end;
  mirH := Attr(ge, 'draw:mirror-horizontal') = 'true';
  mirV := Attr(ge, 'draw:mirror-vertical') = 'true';
  if ctx.VB.Width > 0 then sx := Box.W / ctx.VB.Width else sx := 1;
  if ctx.VB.Height > 0 then sy := Box.H / ctx.VB.Height else sy := 1;
  // tokens: commands are single capital letters; numbers and references
  path := StringReplace(path, ',', ' ', [rfReplaceAll]);
  toks := nil;
  tok := '';
  for n := 1 to Length(path) + 1 do
    if (n > Length(path)) or (path[n] in [' ', #9, #10, #13]) then
    begin
      if tok <> '' then begin SetLength(toks, Length(toks) + 1); toks[High(toks)] := tok; tok := ''; end;
    end
    else if (path[n] in ['A'..'Z']) and (tok = '') then
    begin
      SetLength(toks, Length(toks) + 1);
      toks[High(toks)] := path[n];
    end
    else tok := tok + path[n];
  P := Default(TXVPath);
  P.Clear;
  nf := False; ns := False;
  cur := XVPt(0, 0);
  i := 0;
  cmd := 'M';
  while i <= High(toks) do
  begin
    if (Length(toks[i]) = 1) and (toks[i][1] in ['A'..'Z']) then
    begin
      cmd := toks[i][1];
      Inc(i);
      case cmd of
        'Z': begin P.Close; Continue; end;
        'N': begin Flush; Continue; end;
        'F': begin nf := True; Continue; end;
        'S': begin ns := True; Continue; end;
        'H', 'I', 'J', 'K': Continue;
      end;
    end;
    if not IsNum then begin Inc(i); Continue; end;
    case cmd of
      'M': begin x := Num; y := Num; MapXY(x, y, ox, oy); P.MoveTo(ox, oy); cur := XVPt(x, y); cmd := 'L'; end;
      'L': begin x := Num; y := Num; MapXY(x, y, ox, oy); P.LineTo(ox, oy); cur := XVPt(x, y); end;
      'C': begin
             x1 := Num; y1 := Num; x2 := Num; y2 := Num; x := Num; y := Num;
             MapXY(x1, y1, ox1, oy1); MapXY(x2, y2, ox2, oy2); MapXY(x, y, ox, oy);
             P.CubicTo(ox1, oy1, ox2, oy2, ox, oy);
             cur := XVPt(x, y);
           end;
      'Q': begin
             x1 := Num; y1 := Num; x := Num; y := Num;
             MapXY(x1, y1, ox1, oy1); MapXY(x, y, ox, oy);
             P.QuadTo(ox1, oy1, ox, oy);
             cur := XVPt(x, y);
           end;
      'T': AngleEllipse(False);
      'U': AngleEllipse(True);
      'A': BoxArc(False, False);
      'B': BoxArc(False, True);
      'W': BoxArc(True, False);
      'V': BoxArc(True, True);
      'X', 'Y':
        begin
          horiz := cmd = 'X';
          Quadrant(horiz);
          // X and Y alternate when repeated
          if cmd = 'X' then cmd := 'Y' else cmd := 'X';
        end;
      'G': begin
             // arcangleto: radii, start angle and sweep in degrees, from the current point
             wr := Num; hr := Num; st := DegToRad(Num); swa := DegToRad(Num);
             cx := cur.X - wr * Cos(st); cy := cur.Y - hr * Sin(st);
             LArc(cx, cy, wr, hr, st, swa, 0);
           end;
    else
      Inc(i);
    end;
  end;
  Flush;
  Result := Length(Parts) > 0;
end;

// ------------------------------ shapes -------------------------------------

procedure TOdgReader.Shape(E: TDOMElement; const Parent: TXVMatrix);
var
  n, st, href, kind: string;
  M: TXVMatrix;
  box: TOdgBox;
  P: TXVPath;
  a: TStringArray;
  vb: TXVRect;
  i, corners: Integer;
  r, a0, a1, sw, sx, sy, cr: Double;
  c: TDOMNode;
  parts: TArray<TXVPath>;
  nofill, nostroke: TArray<Boolean>;
  img: TXVImage;
  data: TBytes;
  fill: TXVPaint;
  stroke: TXVStroke;
  hatch, textbox: Boolean;
  sharp, ang: Double;
  sub: TXVDocument;
begin
  n := LName(E);
  st := Attr(E, 'draw:style-name');
  M := ShapeMatrix(E, Parent, box);
  P := Default(TXVPath);
  P.Clear;
  if n = 'g' then
  begin
    Children(E, Parent);
    Exit;
  end;
  if n = 'rect' then
  begin
    cr := Len(Attr(E, 'draw:corner-radius'));
    if cr > 0 then P.AddRoundRect(box.X, box.Y, box.W, box.H, cr, cr) else P.AddRect(box.X, box.Y, box.W, box.H);
    Emit(E, st, P, M, True);
    ShapeText(E, st, box, M, False);
  end
  else if (n = 'ellipse') or (n = 'circle') then
  begin
    kind := Attr(E, 'draw:kind');
    if (kind = '') or (kind = 'full') then P.AddEllipse(box.X + box.W / 2, box.Y + box.H / 2, box.W / 2, box.H / 2)
    else
    begin
      a0 := OdfAngle(Attr(E, 'draw:start-angle') + 'deg'); a1 := OdfAngle(Attr(E, 'draw:end-angle') + 'deg');
      sw := a1 - a0;
      while sw <= 0 do sw := sw + 2 * Pi;
      // counter-clockwise on the page
      P.ArcCenter(box.X + box.W / 2, box.Y + box.H / 2, box.W / 2, box.H / 2, 0, -a0, -sw, 1);
      if kind = 'section' then begin P.LineTo(box.X + box.W / 2, box.Y + box.H / 2); P.Close; end
      else if kind = 'cut' then P.Close;
    end;
    Emit(E, st, P, M, kind <> 'arc');
    ShapeText(E, st, box, M, False);
  end
  else if (n = 'line') or (n = 'measure') then
  begin
    P.MoveTo(Len(Attr(E, 'svg:x1')), Len(Attr(E, 'svg:y1')));
    P.LineTo(Len(Attr(E, 'svg:x2')), Len(Attr(E, 'svg:y2')));
    Emit(E, st, P, Parent, False);
  end
  else if (n = 'polyline') or (n = 'polygon') or (n = 'path') or (n = 'connector') then
  begin
    a := Attr(E, 'svg:viewBox').Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Length(a) >= 4 then vb := XVRect(XVStrToFloat(a[0]), XVStrToFloat(a[1]), XVStrToFloat(a[0]) + XVStrToFloat(a[2]),
      XVStrToFloat(a[1]) + XVStrToFloat(a[3]))
    else vb := XVRect(0, 0, 0, 0);
    if n = 'path' then XVParseSvgPathData(Attr(E, 'svg:d'), P)
    else if n = 'connector' then
    begin
      if Attr(E, 'svg:d') <> '' then
      begin
        // connector paths are in 1/100 mm of the page
        XVParseSvgPathData(Attr(E, 'svg:d'), P);
        if vb.IsEmpty then P.Transform(TXVMatrix.Scale(96 / 2540, 96 / 2540));
      end
      else
      begin
        P.MoveTo(Len(Attr(E, 'svg:x1')), Len(Attr(E, 'svg:y1')));
        P.LineTo(Len(Attr(E, 'svg:x2')), Len(Attr(E, 'svg:y2')));
      end;
      Emit(E, st, P, Parent, False);
      Exit;
    end
    else
    begin
      a := Attr(E, 'draw:points').Split([' ', ','], TStringSplitOptions.ExcludeEmpty);
      for i := 0 to Length(a) div 2 - 1 do
        if i = 0 then P.MoveTo(XVStrToFloat(a[0]), XVStrToFloat(a[1]))
        else P.LineTo(XVStrToFloat(a[2 * i]), XVStrToFloat(a[2 * i + 1]));
      if n = 'polygon' then P.Close;
    end;
    // view box -> shape box
    if not vb.IsEmpty then
    begin
      sx := box.W / vb.Width; sy := box.H / vb.Height;
      P.Transform(TXVMatrix.Make(sx, 0, 0, sy, box.X - vb.Left * sx, box.Y - vb.Top * sy));
    end;
    Emit(E, st, P, M, (n = 'polygon') or ((n = 'path') and (Pos('z', LowerCase(Attr(E, 'svg:d'))) > 0)));
    ShapeText(E, st, box, M, False);
  end
  else if n = 'regular-polygon' then
  begin
    corners := Max(3, StrToIntDef(Attr(E, 'draw:corners'), 3));
    sharp := XVStrToFloat(StringReplace(Attr(E, 'draw:sharpness'), '%', '', []), 0) / 100;
    for i := 0 to (corners * (1 + Ord(Attr(E, 'draw:concave') = 'true'))) - 1 do
    begin
      if Attr(E, 'draw:concave') = 'true' then
      begin
        ang := -Pi / 2 + i * Pi / corners;
        if Odd(i) then r := 1 - sharp else r := 1;
      end
      else
      begin
        ang := -Pi / 2 + i * 2 * Pi / corners;
        r := 1;
      end;
      if i = 0 then P.MoveTo(box.X + box.W / 2 * (1 + r * Cos(ang)), box.Y + box.H / 2 * (1 + r * Sin(ang)))
      else P.LineTo(box.X + box.W / 2 * (1 + r * Cos(ang)), box.Y + box.H / 2 * (1 + r * Sin(ang)));
    end;
    P.Close;
    Emit(E, st, P, M, True);
  end
  else if n = 'custom-shape' then
  begin
    if CustomShape(E, box, parts, nofill, nostroke) then
    begin
      // one fill over the filled parts, then the outlines
      for i := 0 to High(parts) do
      begin
        P := parts[i].Copy;
        P.Transform(M);
        if not nofill[i] then
        begin
          fill := MakeFill(st, P, hatch);
          if fill.Kind <> pkNone then Doc.AddPath(P, fill, XVNoStroke, frEvenOdd);
          if hatch then HatchFill(st, P);
        end;
      end;
      stroke := MakeStroke(st, M);
      if stroke.Paint.Kind <> pkNone then
        for i := 0 to High(parts) do
          if not nostroke[i] then
          begin
            P := parts[i].Copy;
            P.Transform(M);
            Doc.AddPath(P, XVNoPaint, stroke, frEvenOdd);
          end;
    end;
    ShapeText(E, st, box, M, False);
  end
  else if (n = 'frame') or (n = 'caption') then
  begin
    textbox := False;
    if n = 'caption' then
    begin
      P.AddRect(box.X, box.Y, box.W, box.H);
      Emit(E, st, P, M, True);
    end;
    c := E.FirstChild;
    while c <> nil do
    begin
      if c is TDOMElement then
      begin
        if LName(c) = 'image' then
        begin
          href := Attr(c, 'xlink:href');
          data := XVZipReadName(Zip, ZipList, href);
          if (Length(data) > 0) and XVDecodeImage(data, img) and (img.W > 0) and (img.H > 0) then
          begin
            Doc.AddImage(Doc.AddImageData(img), XVMul(M, TXVMatrix.Make(box.W / img.W, 0, 0, box.H / img.H, box.X, box.Y)), 1);
            Break;                 // the first image of the frame (others are replacements)
          end;
          // a vector image (SVG, EMF, WMF ...) is read as a drawing
          if (Length(data) > 0) and (XVDetectFormat(data, href) <> '') then
          begin
            sub := TXVDocument.Create;
            try
              try
                sub.LoadFromBytes(data, href);
                if sub.Count > 0 then
                begin
                  Doc.AppendDocumentInto(sub, box.X, box.Y, box.W, box.H, M);
                  Break;
                end;
              except
                // the replacement image comes next
              end;
            finally
              sub.Free;
            end;
          end;
        end
        else if LName(c) = 'text-box' then textbox := True;
      end;
      c := c.NextSibling;
    end;
    if textbox then
    begin
      P.Clear;
      P.AddRect(box.X, box.Y, box.W, box.H);
      Emit(E, st, P, M, True);
      ShapeText(E, st, box, M, True);
    end;
  end;
end;

procedure TOdgReader.Children(E: TDOMNode; const M: TXVMatrix);
var c: TDOMNode;
begin
  c := E.FirstChild;
  while c <> nil do
  begin
    if c is TDOMElement then
      try
        Shape(TDOMElement(c), M);
      except
        // a damaged shape is skipped
      end;
    c := c.NextSibling;
  end;
end;

procedure TOdgReader.Run;
var
  body, page, c, mp, ml: TDOMNode;
  pages: array of TDOMNode;
  i: Integer;
  mpName, plName: string;
  w, h: Double;
  bg: TXVColor;
  dpst: string;
begin
  ZipList := XVZipList(Zip);
  if Length(ZipList) > 0 then
  begin
    Content := ParseDoc('content.xml');
    Styles := ParseDoc('styles.xml');
  end
  else
  begin
    // flat XML document (.fodg): styles and content in one tree
    Content := ParseFlat;
    Styles := Content;
  end;
  if Content = nil then raise EXVError.Create('ODG: no content');
  if Styles <> nil then
  begin
    LoadStyles(Styles.DocumentElement, '');
    CollectNamed(Styles.DocumentElement);
  end;
  LoadStyles(Content.DocumentElement, '');
  CollectNamed(Content.DocumentElement);
  // pages of the drawing (or presentation)
  body := nil;
  c := Content.DocumentElement.FirstChild;
  while c <> nil do
  begin
    if (c is TDOMElement) and (LName(c) = 'body') then body := c;
    c := c.NextSibling;
  end;
  if body = nil then raise EXVError.Create('ODG: no body');
  pages := nil;
  c := body.FirstChild;
  while c <> nil do
  begin
    if (c is TDOMElement) and ((LName(c) = 'drawing') or (LName(c) = 'presentation')) then
    begin
      page := c.FirstChild;
      while page <> nil do
      begin
        if (page is TDOMElement) and (LName(page) = 'page') then
        begin
          SetLength(pages, Length(pages) + 1);
          pages[High(pages)] := page;
        end;
        page := page.NextSibling;
      end;
    end;
    c := c.NextSibling;
  end;
  if Length(pages) = 0 then raise EXVError.Create('ODG: no page');
  Doc.PageCount := Length(pages);
  page := pages[EnsureRange(Doc.LoadPage, 0, High(pages))];
  // page size from the master page's layout
  w := Len('21cm'); h := Len('29.7cm');
  mpName := Attr(page, 'draw:master-page-name');
  mp := nil;
  if Styles <> nil then
  begin
    c := Styles.DocumentElement.FirstChild;
    while c <> nil do
    begin
      if (c is TDOMElement) and (LName(c) = 'master-styles') then
      begin
        ml := c.FirstChild;
        while ml <> nil do
        begin
          if (ml is TDOMElement) and (LName(ml) = 'master-page') and ((Attr(ml, 'style:name') = mpName) or (mp = nil)) then
            mp := ml;
          ml := ml.NextSibling;
        end;
      end;
      c := c.NextSibling;
    end;
  end;
  if mp <> nil then
  begin
    plName := Attr(mp, 'style:page-layout-name');
    // the page layout is an automatic style of styles.xml
    c := Styles.DocumentElement.FirstChild;
    while c <> nil do
    begin
      if (c is TDOMElement) and (LName(c) = 'automatic-styles') then
      begin
        ml := c.FirstChild;
        while ml <> nil do
        begin
          if (ml is TDOMElement) and (LName(ml) = 'page-layout') and (Attr(ml, 'style:name') = plName) then
          begin
            if ml.FirstChild <> nil then
            begin
              c := ml.FirstChild;
              while (c <> nil) and not ((c is TDOMElement) and (LName(c) = 'page-layout-properties')) do c := c.NextSibling;
              if c <> nil then
              begin
                w := Len(Attr(c, 'fo:page-width'), 0, w);
                h := Len(Attr(c, 'fo:page-height'), 0, h);
              end;
            end;
            Break;
          end;
          ml := ml.NextSibling;
        end;
        Break;
      end;
      c := c.NextSibling;
    end;
  end;
  Doc.SetPageSize(w, h);
  // page background colour
  dpst := Attr(page, 'draw:style-name');
  if (Prop(dpst, 'drawing-page:fill') = 'solid') and ParseColor(Prop(dpst, 'drawing-page:fill-color'), bg) then Doc.Background := bg
  else Doc.Background := XV_WHITE;
  // master page objects, then the page
  if mp <> nil then Children(mp, TXVMatrix.Identity);
  Children(page, TXVMatrix.Identity);
end;

function XVIsODG(const Data: TBytes): Boolean;
var s: string;
begin
  Result := False;
  if Length(Data) < 80 then Exit;
  SetLength(s, 80);
  Move(Data[0], s[1], 80);
  // "mimetype" stored first: application/vnd.oasis.opendocument.graphics
  if (Data[0] = Ord('P')) and (Data[1] = Ord('K')) then
    Result := (Pos('mimetypeapplication/vnd.oasis.opendocument.graphics', s) > 0) or
      (Pos('mimetypeapplication/vnd.oasis.opendocument.presentation', s) > 0)
  else
  begin
    SetLength(s, Min(Length(Data), 4096));
    Move(Data[0], s[1], Length(s));
    Result := (Pos('<office:document', s) > 0) and (Pos('opendocument.graphics', s) > 0);
  end;
end;

procedure XVReadODGDoc(Doc: TXVDocument; const Data: TBytes);
var
  R: TOdgReader;
  i: Integer;
begin
  R := TOdgReader.Create;
  try
    R.Doc := Doc;
    R.Zip := Data;
    R.StyleIdx := TStringList.Create;
    R.Named := TStringList.Create;
    R.Fonts := TStringList.Create;
    R.DefaultStyle := -1;
    try
      R.Run;
    finally
      for i := 0 to High(R.StyleList) do R.StyleList[i].Props.Free;
      R.StyleIdx.Free;
      R.Named.Free;
      R.Fonts.Free;
      if R.Styles <> R.Content then R.Styles.Free;
      R.Content.Free;
    end;
  finally
    R.Free;
  end;
end;

initialization
  XVRegisterReader('ODG', 'odg;otg;fodg;odp', XVIsODG, XVReadODGDoc);
end.
