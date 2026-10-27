unit XVReadSVG;

{$mode delphi}{$H+}
{$R-}{$Q-}

// XelVectors - SVG reader.
//
// The XML tree is walked with a computed style (presentation attributes, CSS
// rules from <style> with type / class / id selectors, the style attribute;
// inherited properties flow down) and a current transform. Shapes become
// paths in document space, <text>/<tspan> runs become text elements, <image>
// with data: URIs becomes an image. Linear and radial gradients (href
// inheritance, objectBoundingBox units, gradientTransform, spreadMethod),
// clip paths, <use>/<symbol>, nested <svg> viewports, markers and opacity are
// kept. Pattern fills fall back to the colour of the pattern's content;
// masks and filters are ignored.

interface

uses
  SysUtils, Classes, Math, DOM, XMLRead, XVModel, XVImageCodec;

function XVIsSVG(const Data: TBytes): Boolean;
procedure XVReadSVGDoc(Doc: TXVDocument; const Data: TBytes);

// helpers shared with the other XML based readers
function XVParseCssColor(const S: string; out C: TXVColor; CurrentColor: TXVColor = XV_BLACK): Boolean;
procedure XVParseSvgPathData(const D: string; var P: TXVPath);

implementation

type
  TSvgStyle = record
    Fill, Stroke: string;
    FillOpacity, StrokeOpacity: Double;
    FillRule, ClipRule: TXVFillRule;
    StrokeWidth: Double;
    LineCap: TXVLineCap;
    LineJoin: TXVLineJoin;
    MiterLimit: Double;
    DashArray: string;
    DashOffset: Double;
    Color: TXVColor;
    FontFamily: string;
    FontSize: Double;
    FontWeight: Integer;
    Italic: Boolean;
    Decoration: string;
    Anchor: TXVTextAnchor;
    Baseline: TXVTextBaseline;
    Visible: Boolean;
    MarkerStart, MarkerMid, MarkerEnd: string;
    // not inherited
    Opacity: Double;
    Display: Boolean;
    NonScaling: Boolean;           // vector-effect: non-scaling-stroke
    ClipPath: string;
    StopColor: string;
    StopOpacity: Double;
  end;

  TCssRule = record
    Tag, Id: string;
    Classes: TStringArray;
    Spec, Order: Integer;
    Body: string;
  end;

  TSvgCtx = record
    CTM: TXVMatrix;
    VW, VH: Double;                 // viewport size for percentages
  end;

  { TSvgReader }

  TSvgReader = class
  private
    Doc: TXVDocument;
    XDoc: TXMLDocument;
    Ids: TStringList;
    Css: array of TCssRule;
    GradCache: TStringList;
    Depth: Integer;
    procedure CollectIds(N: TDOMNode);
    procedure CollectCss(N: TDOMNode);
    procedure ParseCss(const Text: string);
    function FindId(const Ref: string): TDOMElement;
    function ElemName(N: TDOMNode): string;
    function Attr(N: TDOMNode; const Name: string): string;
    function HasAttr(N: TDOMNode; const Name: string): Boolean;
    function Href(N: TDOMNode): string;
    procedure ApplyProp(var St: TSvgStyle; const Name, Value: string; const Parent: TSvgStyle);
    procedure ApplyDecls(var St: TSvgStyle; const Decls: string; const Parent: TSvgStyle);
    function ComputeStyle(E: TDOMElement; const Parent: TSvgStyle): TSvgStyle;
    function Len(const S: string; Ref, FontSize: Double; Def: Double = 0): Double;
    function LenX(E: TDOMNode; const Name: string; const Ctx: TSvgCtx; const St: TSvgStyle; Def: Double = 0): Double;
    function LenY(E: TDOMNode; const Name: string; const Ctx: TSvgCtx; const St: TSvgStyle; Def: Double = 0): Double;
    function LenD(E: TDOMNode; const Name: string; const Ctx: TSvgCtx; const St: TSvgStyle; Def: Double = 0): Double;
    function ResolvePaint(const V: string; Opacity: Double; const St: TSvgStyle; const UserBox: TXVRect;
      const CTM: TXVMatrix): TXVPaint;
    function MakeGradient(E: TDOMElement; Opacity: Double; const St: TSvgStyle; const UserBox: TXVRect;
      const CTM: TXVMatrix; out AvgColor: TXVColor): Integer;
    function PatternColor(E: TDOMElement; const St: TSvgStyle): TXVColor;
    function ShapePath(E: TDOMElement; const Ctx: TSvgCtx; const St: TSvgStyle; out P: TXVPath): Boolean;
    function BuildClip(const Ref: string; const Ctx: TSvgCtx; const UserBox: TXVRect): Integer;
    procedure EmitShape(E: TDOMElement; const Ctx: TSvgCtx; const St: TSvgStyle);
    procedure EmitMarkers(const UserPath: TXVPath; const Ctx: TSvgCtx; const St: TSvgStyle);
    procedure EmitText(E: TDOMElement; const Ctx: TSvgCtx; const St: TSvgStyle);
    procedure EmitImage(E: TDOMElement; const Ctx: TSvgCtx; const St: TSvgStyle);
    procedure Node(E: TDOMElement; const Ctx: TSvgCtx; const Parent: TSvgStyle);
    procedure Children(E: TDOMElement; const Ctx: TSvgCtx; const St: TSvgStyle);
    function ViewBoxMatrix(const VB: string; const AspectRatio: string; X, Y, W, H: Double; out Ok: Boolean): TXVMatrix;
  public
    constructor Create(ADoc: TXVDocument);
    destructor Destroy; override;
    procedure Run(const Data: TBytes);
  end;

// ------------------------------ colours ------------------------------------

type
  TNamedColor = record
    N: string;
    C: Cardinal;
  end;

const
  NAMED_COLORS: array[0..147] of TNamedColor = (
    (N: 'aliceblue'; C: $F0F8FF), (N: 'antiquewhite'; C: $FAEBD7), (N: 'aqua'; C: $00FFFF),
    (N: 'aquamarine'; C: $7FFFD4), (N: 'azure'; C: $F0FFFF), (N: 'beige'; C: $F5F5DC),
    (N: 'bisque'; C: $FFE4C4), (N: 'black'; C: $000000), (N: 'blanchedalmond'; C: $FFEBCD),
    (N: 'blue'; C: $0000FF), (N: 'blueviolet'; C: $8A2BE2), (N: 'brown'; C: $A52A2A),
    (N: 'burlywood'; C: $DEB887), (N: 'cadetblue'; C: $5F9EA0), (N: 'chartreuse'; C: $7FFF00),
    (N: 'chocolate'; C: $D2691E), (N: 'coral'; C: $FF7F50), (N: 'cornflowerblue'; C: $6495ED),
    (N: 'cornsilk'; C: $FFF8DC), (N: 'crimson'; C: $DC143C), (N: 'cyan'; C: $00FFFF),
    (N: 'darkblue'; C: $00008B), (N: 'darkcyan'; C: $008B8B), (N: 'darkgoldenrod'; C: $B8860B),
    (N: 'darkgray'; C: $A9A9A9), (N: 'darkgreen'; C: $006400), (N: 'darkgrey'; C: $A9A9A9),
    (N: 'darkkhaki'; C: $BDB76B), (N: 'darkmagenta'; C: $8B008B), (N: 'darkolivegreen'; C: $556B2F),
    (N: 'darkorange'; C: $FF8C00), (N: 'darkorchid'; C: $9932CC), (N: 'darkred'; C: $8B0000),
    (N: 'darksalmon'; C: $E9967A), (N: 'darkseagreen'; C: $8FBC8F), (N: 'darkslateblue'; C: $483D8B),
    (N: 'darkslategray'; C: $2F4F4F), (N: 'darkslategrey'; C: $2F4F4F), (N: 'darkturquoise'; C: $00CED1),
    (N: 'darkviolet'; C: $9400D3), (N: 'deeppink'; C: $FF1493), (N: 'deepskyblue'; C: $00BFFF),
    (N: 'dimgray'; C: $696969), (N: 'dimgrey'; C: $696969), (N: 'dodgerblue'; C: $1E90FF),
    (N: 'firebrick'; C: $B22222), (N: 'floralwhite'; C: $FFFAF0), (N: 'forestgreen'; C: $228B22),
    (N: 'fuchsia'; C: $FF00FF), (N: 'gainsboro'; C: $DCDCDC), (N: 'ghostwhite'; C: $F8F8FF),
    (N: 'gold'; C: $FFD700), (N: 'goldenrod'; C: $DAA520), (N: 'gray'; C: $808080),
    (N: 'grey'; C: $808080), (N: 'green'; C: $008000), (N: 'greenyellow'; C: $ADFF2F),
    (N: 'honeydew'; C: $F0FFF0), (N: 'hotpink'; C: $FF69B4), (N: 'indianred'; C: $CD5C5C),
    (N: 'indigo'; C: $4B0082), (N: 'ivory'; C: $FFFFF0), (N: 'khaki'; C: $F0E68C),
    (N: 'lavender'; C: $E6E6FA), (N: 'lavenderblush'; C: $FFF0F5), (N: 'lawngreen'; C: $7CFC00),
    (N: 'lemonchiffon'; C: $FFFACD), (N: 'lightblue'; C: $ADD8E6), (N: 'lightcoral'; C: $F08080),
    (N: 'lightcyan'; C: $E0FFFF), (N: 'lightgoldenrodyellow'; C: $FAFAD2), (N: 'lightgray'; C: $D3D3D3),
    (N: 'lightgreen'; C: $90EE90), (N: 'lightgrey'; C: $D3D3D3), (N: 'lightpink'; C: $FFB6C1),
    (N: 'lightsalmon'; C: $FFA07A), (N: 'lightseagreen'; C: $20B2AA), (N: 'lightskyblue'; C: $87CEFA),
    (N: 'lightslategray'; C: $778899), (N: 'lightslategrey'; C: $778899), (N: 'lightsteelblue'; C: $B0C4DE),
    (N: 'lightyellow'; C: $FFFFE0), (N: 'lime'; C: $00FF00), (N: 'limegreen'; C: $32CD32),
    (N: 'linen'; C: $FAF0E6), (N: 'magenta'; C: $FF00FF), (N: 'maroon'; C: $800000),
    (N: 'mediumaquamarine'; C: $66CDAA), (N: 'mediumblue'; C: $0000CD), (N: 'mediumorchid'; C: $BA55D3),
    (N: 'mediumpurple'; C: $9370DB), (N: 'mediumseagreen'; C: $3CB371), (N: 'mediumslateblue'; C: $7B68EE),
    (N: 'mediumspringgreen'; C: $00FA9A), (N: 'mediumturquoise'; C: $48D1CC), (N: 'mediumvioletred'; C: $C71585),
    (N: 'midnightblue'; C: $191970), (N: 'mintcream'; C: $F5FFFA), (N: 'mistyrose'; C: $FFE4E1),
    (N: 'moccasin'; C: $FFE4B5), (N: 'navajowhite'; C: $FFDEAD), (N: 'navy'; C: $000080),
    (N: 'oldlace'; C: $FDF5E6), (N: 'olive'; C: $808000), (N: 'olivedrab'; C: $6B8E23),
    (N: 'orange'; C: $FFA500), (N: 'orangered'; C: $FF4500), (N: 'orchid'; C: $DA70D6),
    (N: 'palegoldenrod'; C: $EEE8AA), (N: 'palegreen'; C: $98FB98), (N: 'paleturquoise'; C: $AFEEEE),
    (N: 'palevioletred'; C: $DB7093), (N: 'papayawhip'; C: $FFEFD5), (N: 'peachpuff'; C: $FFDAB9),
    (N: 'peru'; C: $CD853F), (N: 'pink'; C: $FFC0CB), (N: 'plum'; C: $DDA0DD),
    (N: 'powderblue'; C: $B0E0E6), (N: 'purple'; C: $800080), (N: 'rebeccapurple'; C: $663399),
    (N: 'red'; C: $FF0000), (N: 'rosybrown'; C: $BC8F8F), (N: 'royalblue'; C: $4169E1),
    (N: 'saddlebrown'; C: $8B4513), (N: 'salmon'; C: $FA8072), (N: 'sandybrown'; C: $F4A460),
    (N: 'seagreen'; C: $2E8B57), (N: 'seashell'; C: $FFF5EE), (N: 'sienna'; C: $A0522D),
    (N: 'silver'; C: $C0C0C0), (N: 'skyblue'; C: $87CEEB), (N: 'slateblue'; C: $6A5ACD),
    (N: 'slategray'; C: $708090), (N: 'slategrey'; C: $708090), (N: 'snow'; C: $FFFAFA),
    (N: 'springgreen'; C: $00FF7F), (N: 'steelblue'; C: $4682B4), (N: 'tan'; C: $D2B48C),
    (N: 'teal'; C: $008080), (N: 'thistle'; C: $D8BFD8), (N: 'tomato'; C: $FF6347),
    (N: 'turquoise'; C: $40E0D0), (N: 'violet'; C: $EE82EE), (N: 'wheat'; C: $F5DEB3),
    (N: 'white'; C: $FFFFFF), (N: 'whitesmoke'; C: $F5F5F5), (N: 'yellow'; C: $FFFF00),
    (N: 'yellowgreen'; C: $9ACD32));

function HexVal(c: Char): Integer;
begin
  case c of
    '0'..'9': Result := Ord(c) - 48;
    'a'..'f': Result := Ord(c) - 87;
    'A'..'F': Result := Ord(c) - 55;
  else
    Result := -1;
  end;
end;

function SplitArgs(const S: string): TStringArray;
var
  i, n: Integer;
  t: string;
begin
  Result := nil;
  n := 0;
  t := '';
  for i := 1 to Length(S) + 1 do
    if (i > Length(S)) or (S[i] in [',', ' ', #9, #10, #13, '/']) then
    begin
      if t <> '' then
      begin
        SetLength(Result, n + 1);
        Result[n] := t;
        Inc(n);
        t := '';
      end;
    end
    else t := t + S[i];
end;

function ColorComp(const S: string; Max255: Boolean): Integer;
var v: Double;
begin
  if (S <> '') and (S[Length(S)] = '%') then
    v := XVStrToFloat(Copy(S, 1, Length(S) - 1), 0) * 2.55
  else
    v := XVStrToFloat(S, 0);
  Result := EnsureRange(Round(v), 0, 255);
end;

function AlphaComp(const S: string): Integer;
var v: Double;
begin
  if (S <> '') and (S[Length(S)] = '%') then v := XVStrToFloat(Copy(S, 1, Length(S) - 1), 100) / 100
  else v := XVStrToFloat(S, 1);
  Result := EnsureRange(Round(v * 255), 0, 255);
end;

function HslToRgb(h, s, l: Double): Cardinal;

  function Hue(p, q, t: Double): Double;
  begin
    if t < 0 then t := t + 1;
    if t > 1 then t := t - 1;
    if t < 1 / 6 then Exit(p + (q - p) * 6 * t);
    if t < 1 / 2 then Exit(q);
    if t < 2 / 3 then Exit(p + (q - p) * (2 / 3 - t) * 6);
    Result := p;
  end;

var p, q, r, g, b: Double;
begin
  h := h - Floor(h);
  if s = 0 then begin r := l; g := l; b := l; end
  else
  begin
    if l < 0.5 then q := l * (1 + s) else q := l + s - l * s;
    p := 2 * l - q;
    r := Hue(p, q, h + 1 / 3); g := Hue(p, q, h); b := Hue(p, q, h - 1 / 3);
  end;
  Result := (Cardinal(EnsureRange(Round(r * 255), 0, 255)) shl 16) or
    (Cardinal(EnsureRange(Round(g * 255), 0, 255)) shl 8) or Cardinal(EnsureRange(Round(b * 255), 0, 255));
end;

function XVParseCssColor(const S: string; out C: TXVColor; CurrentColor: TXVColor): Boolean;
var
  t, inner: string;
  a: TStringArray;
  i, p: Integer;
  h1: array[0..7] of Integer;
begin
  Result := False;
  C := XV_BLACK;
  t := LowerCase(Trim(S));
  if t = '' then Exit;
  if t = 'currentcolor' then begin C := CurrentColor; Exit(True); end;
  if t = 'transparent' then begin C := 0; Exit(True); end;
  if t[1] = '#' then
  begin
    for i := 0 to 7 do
      if i + 2 <= Length(t) then h1[i] := HexVal(t[i + 2]) else h1[i] := 0;
    case Length(t) of
      4: C := XVRGB(h1[0] * 17, h1[1] * 17, h1[2] * 17);
      5: C := XVRGBA(h1[0] * 17, h1[1] * 17, h1[2] * 17, h1[3] * 17);
      7: C := XVRGB(h1[0] * 16 + h1[1], h1[2] * 16 + h1[3], h1[4] * 16 + h1[5]);
      9: C := XVRGBA(h1[0] * 16 + h1[1], h1[2] * 16 + h1[3], h1[4] * 16 + h1[5], h1[6] * 16 + h1[7]);
    else
      Exit;
    end;
    for i := 2 to Length(t) do if HexVal(t[i]) < 0 then Exit;
    Exit(True);
  end;
  p := Pos('(', t);
  if p > 0 then
  begin
    inner := Copy(t, p + 1, Length(t));
    if Pos(')', inner) > 0 then inner := Copy(inner, 1, Pos(')', inner) - 1);
    a := SplitArgs(inner);
    if (Copy(t, 1, 3) = 'rgb') and (Length(a) >= 3) then
    begin
      C := XVRGB(ColorComp(a[0], True), ColorComp(a[1], True), ColorComp(a[2], True));
      if Length(a) >= 4 then C := XVWithAlpha(C, AlphaComp(a[3]));
      Exit(True);
    end;
    if (Copy(t, 1, 3) = 'hsl') and (Length(a) >= 3) then
    begin
      C := $FF000000 or HslToRgb(XVStrToFloat(StringReplace(a[0], 'deg', '', []), 0) / 360,
        XVStrToFloat(StringReplace(a[1], '%', '', []), 0) / 100, XVStrToFloat(StringReplace(a[2], '%', '', []), 0) / 100);
      if Length(a) >= 4 then C := XVWithAlpha(C, AlphaComp(a[3]));
      Exit(True);
    end;
    Exit;
  end;
  for i := 0 to High(NAMED_COLORS) do
    if NAMED_COLORS[i].N = t then
    begin
      C := $FF000000 or NAMED_COLORS[i].C;
      Exit(True);
    end;
  // system colours of SVG 1.1
  if (t = 'windowtext') or (t = 'buttontext') or (t = 'captiontext') or (t = 'menutext') then begin C := XV_BLACK; Exit(True); end;
  if (t = 'window') or (t = 'buttonface') or (t = 'menu') then begin C := XV_WHITE; Exit(True); end;
end;

// ------------------------------ path data ----------------------------------

type
  TPathScan = record
    S: string;
    P: Integer;
    procedure SkipSep;
    function AtNumber: Boolean;
    function Num(out V: Double): Boolean;
    function Flag(out V: Boolean): Boolean;
  end;

procedure TPathScan.SkipSep;
begin
  while (P <= Length(S)) and (S[P] in [' ', #9, #10, #13, ',']) do Inc(P);
end;

function TPathScan.AtNumber: Boolean;
begin
  SkipSep;
  Result := (P <= Length(S)) and (S[P] in ['0'..'9', '.', '-', '+']);
end;

function TPathScan.Num(out V: Double): Boolean;
var st, code: Integer;
    dot, ex: Boolean;
begin
  V := 0;
  SkipSep;
  st := P;
  if (P <= Length(S)) and (S[P] in ['+', '-']) then Inc(P);
  dot := False; ex := False;
  while P <= Length(S) do
  begin
    if S[P] in ['0'..'9'] then Inc(P)
    else if (S[P] = '.') and not dot and not ex then begin dot := True; Inc(P); end
    else if (S[P] in ['e', 'E']) and not ex and (P > st) then
    begin
      // "e" belongs to the number only when digits follow
      if (P + 1 <= Length(S)) and ((S[P + 1] in ['0'..'9']) or
         ((S[P + 1] in ['+', '-']) and (P + 2 <= Length(S)) and (S[P + 2] in ['0'..'9']))) then
      begin
        ex := True;
        Inc(P);
        if S[P] in ['+', '-'] then Inc(P);
      end
      else Break;
    end
    else Break;
  end;
  Result := P > st;
  if not Result then Exit;
  Val(Copy(S, st, P - st), V, code);
  if code <> 0 then V := 0;
end;

function TPathScan.Flag(out V: Boolean): Boolean;
begin
  SkipSep;
  Result := (P <= Length(S)) and (S[P] in ['0', '1']);
  if Result then
  begin
    V := S[P] = '1';
    Inc(P);
  end
  else V := False;
end;

procedure XVParseSvgPathData(const D: string; var P: TXVPath);
var
  sc: TPathScan;
  cmd, prev: Char;
  x, y, x1, y1, x2, y2, rx, ry, rot, cx, cy, lcx, lcy, lqx, lqy: Double;
  large, sweep, rel: Boolean;
  first: Boolean;
begin
  sc.S := D;
  sc.P := 1;
  cmd := #0; prev := #0;
  cx := 0; cy := 0; lcx := 0; lcy := 0; lqx := 0; lqy := 0;
  first := True;
  while True do
  begin
    sc.SkipSep;
    if sc.P > Length(D) then Break;
    if D[sc.P] in ['M', 'm', 'L', 'l', 'H', 'h', 'V', 'v', 'C', 'c', 'S', 's', 'Q', 'q', 'T', 't', 'A', 'a', 'Z', 'z'] then
    begin
      cmd := D[sc.P];
      Inc(sc.P);
      if cmd in ['Z', 'z'] then
      begin
        P.Close;
        if P.HasCurrent then begin cx := P.CurrentPoint.X; cy := P.CurrentPoint.Y; end;
        prev := cmd;
        Continue;
      end;
    end
    else if not sc.AtNumber then begin Inc(sc.P); Continue; end
    else if cmd = #0 then Break;
    rel := cmd in ['a'..'z'];
    if first and (cmd = 'm') then rel := False;
    case UpCase(cmd) of
      'M':
        begin
          if not (sc.Num(x) and sc.Num(y)) then Break;
          if rel then begin x := x + cx; y := y + cy; end;
          P.MoveTo(x, y);
          cx := x; cy := y;
          // further coordinate pairs are line-tos of the same kind
          if cmd = 'm' then cmd := 'l' else cmd := 'L';
        end;
      'L':
        begin
          if not (sc.Num(x) and sc.Num(y)) then Break;
          if rel then begin x := x + cx; y := y + cy; end;
          P.LineTo(x, y);
          cx := x; cy := y;
        end;
      'H':
        begin
          if not sc.Num(x) then Break;
          if rel then x := x + cx;
          P.LineTo(x, cy);
          cx := x;
        end;
      'V':
        begin
          if not sc.Num(y) then Break;
          if rel then y := y + cy;
          P.LineTo(cx, y);
          cy := y;
        end;
      'C':
        begin
          if not (sc.Num(x1) and sc.Num(y1) and sc.Num(x2) and sc.Num(y2) and sc.Num(x) and sc.Num(y)) then Break;
          if rel then
          begin
            x1 := x1 + cx; y1 := y1 + cy; x2 := x2 + cx; y2 := y2 + cy; x := x + cx; y := y + cy;
          end;
          P.CubicTo(x1, y1, x2, y2, x, y);
          lcx := x2; lcy := y2;
          cx := x; cy := y;
        end;
      'S':
        begin
          if not (sc.Num(x2) and sc.Num(y2) and sc.Num(x) and sc.Num(y)) then Break;
          if rel then begin x2 := x2 + cx; y2 := y2 + cy; x := x + cx; y := y + cy; end;
          if UpCase(prev) in ['C', 'S'] then begin x1 := 2 * cx - lcx; y1 := 2 * cy - lcy; end
          else begin x1 := cx; y1 := cy; end;
          P.CubicTo(x1, y1, x2, y2, x, y);
          lcx := x2; lcy := y2;
          cx := x; cy := y;
        end;
      'Q':
        begin
          if not (sc.Num(x1) and sc.Num(y1) and sc.Num(x) and sc.Num(y)) then Break;
          if rel then begin x1 := x1 + cx; y1 := y1 + cy; x := x + cx; y := y + cy; end;
          P.QuadTo(x1, y1, x, y);
          lqx := x1; lqy := y1;
          cx := x; cy := y;
        end;
      'T':
        begin
          if not (sc.Num(x) and sc.Num(y)) then Break;
          if rel then begin x := x + cx; y := y + cy; end;
          if UpCase(prev) in ['Q', 'T'] then begin x1 := 2 * cx - lqx; y1 := 2 * cy - lqy; end
          else begin x1 := cx; y1 := cy; end;
          P.QuadTo(x1, y1, x, y);
          lqx := x1; lqy := y1;
          cx := x; cy := y;
        end;
      'A':
        begin
          if not (sc.Num(rx) and sc.Num(ry) and sc.Num(rot) and sc.Flag(large) and sc.Flag(sweep) and
             sc.Num(x) and sc.Num(y)) then Break;
          if rel then begin x := x + cx; y := y + cy; end;
          if not P.HasCurrent then P.MoveTo(cx, cy);
          P.ArcTo(rx, ry, rot, large, sweep, x, y);
          cx := x; cy := y;
        end;
    end;
    first := False;
    prev := cmd;
  end;
end;

// ------------------------------ helpers ------------------------------------

function XVIsSVG(const Data: TBytes): Boolean;
var
  s: string;
  n: Integer;
begin
  n := Min(Length(Data), 4096);
  SetLength(s, n);
  if n > 0 then Move(Data[0], s[1], n);
  s := LowerCase(s);
  Result := (Pos('<svg', s) > 0) and ((Pos('<?xml', s) > 0) or (Pos('<svg', s) < 1024) or (Pos('<!doctype svg', s) > 0));
end;

function ParseTransformList(const T: string): TXVMatrix;
var
  s, fn: string;
  p, q: Integer;
  a: TStringArray;
  v: array[0..5] of Double;
  i: Integer;
  m: TXVMatrix;
begin
  Result := TXVMatrix.Identity;
  s := LowerCase(T);
  p := 1;
  while p <= Length(s) do
  begin
    while (p <= Length(s)) and (s[p] in [' ', #9, #10, #13, ',']) do Inc(p);
    q := p;
    while (q <= Length(s)) and (s[q] in ['a'..'z']) do Inc(q);
    fn := Copy(s, p, q - p);
    if fn = '' then Break;
    p := q;
    while (p <= Length(s)) and (s[p] <> '(') do Inc(p);
    q := p;
    while (q <= Length(s)) and (s[q] <> ')') do Inc(q);
    a := SplitArgs(Copy(s, p + 1, q - p - 1));
    p := q + 1;
    for i := 0 to 5 do
      if i < Length(a) then v[i] := XVStrToFloat(a[i], 0) else v[i] := 0;
    m := TXVMatrix.Identity;
    if fn = 'matrix' then
    begin
      if Length(a) >= 6 then m := TXVMatrix.Make(v[0], v[1], v[2], v[3], v[4], v[5]);
    end
    else if fn = 'translate' then m := TXVMatrix.Translate(v[0], v[1])
    else if fn = 'scale' then
    begin
      if Length(a) >= 2 then m := TXVMatrix.Scale(v[0], v[1])
      else if Length(a) = 1 then m := TXVMatrix.Scale(v[0], v[0]);
    end
    else if fn = 'rotate' then
    begin
      m := TXVMatrix.Rotate(DegToRad(v[0]));
      if Length(a) >= 3 then
        m := XVMul(TXVMatrix.Translate(v[1], v[2]), XVMul(m, TXVMatrix.Translate(-v[1], -v[2])));
    end
    else if fn = 'skewx' then m := TXVMatrix.SkewX(DegToRad(v[0]))
    else if fn = 'skewy' then m := TXVMatrix.SkewY(DegToRad(v[0]));
    Result := XVMul(Result, m);
  end;
end;

function StripPrefix(const S: string): string;
var p: Integer;
begin
  p := Pos(':', S);
  if p > 0 then Result := Copy(S, p + 1, MaxInt) else Result := S;
end;

function UrlId(const V: string): string;
var s: string; p: Integer;
begin
  Result := '';
  s := Trim(V);
  if LowerCase(Copy(s, 1, 4)) = 'url(' then
  begin
    p := Pos(')', s);
    if p = 0 then p := Length(s) + 1;
    s := Trim(Copy(s, 5, p - 5));
    if (s <> '') and (s[1] in ['''', '"']) then s := Copy(s, 2, Length(s) - 2);
  end;
  p := Pos('#', s);
  if p > 0 then Result := Copy(s, p + 1, MaxInt);
end;

function UrlFallback(const V: string): string;
var p: Integer;
begin
  p := Pos(')', V);
  if p > 0 then Result := Trim(Copy(V, p + 1, MaxInt)) else Result := '';
end;

// ------------------------------ reader -------------------------------------

constructor TSvgReader.Create(ADoc: TXVDocument);
begin
  inherited Create;
  Doc := ADoc;
  Ids := TStringList.Create;
  Ids.Sorted := True;
  Ids.Duplicates := dupIgnore;
  Ids.CaseSensitive := True;
  GradCache := TStringList.Create;
end;

destructor TSvgReader.Destroy;
begin
  Ids.Free;
  GradCache.Free;
  XDoc.Free;
  inherited Destroy;
end;

function TSvgReader.ElemName(N: TDOMNode): string;
begin
  Result := LowerCase(StripPrefix(UTF8Encode(N.NodeName)));
end;

function TSvgReader.Attr(N: TDOMNode; const Name: string): string;
var a: TDOMNode;
begin
  Result := '';
  if (N = nil) or (N.Attributes = nil) then Exit;
  a := N.Attributes.GetNamedItem(UTF8Decode(Name));
  if a <> nil then Result := UTF8Encode(a.NodeValue);
end;

function TSvgReader.HasAttr(N: TDOMNode; const Name: string): Boolean;
begin
  Result := (N <> nil) and (N.Attributes <> nil) and (N.Attributes.GetNamedItem(UTF8Decode(Name)) <> nil);
end;

function TSvgReader.Href(N: TDOMNode): string;
var i: Integer; a: TDOMNode;
begin
  Result := Attr(N, 'xlink:href');
  if Result = '' then Result := Attr(N, 'href');
  if (Result = '') and (N.Attributes <> nil) then
    for i := 0 to N.Attributes.Length - 1 do
    begin
      a := N.Attributes.Item[i];
      if LowerCase(StripPrefix(UTF8Encode(a.NodeName))) = 'href' then Exit(UTF8Encode(a.NodeValue));
    end;
end;

procedure TSvgReader.CollectIds(N: TDOMNode);
var c: TDOMNode; id: string;
begin
  if N is TDOMElement then
  begin
    id := Attr(N, 'id');
    if id = '' then id := Attr(N, 'xml:id');
    if id <> '' then Ids.AddObject(id, N);
  end;
  c := N.FirstChild;
  while c <> nil do
  begin
    CollectIds(c);
    c := c.NextSibling;
  end;
end;

function TSvgReader.FindId(const Ref: string): TDOMElement;
var i: Integer; s: string;
begin
  Result := nil;
  s := Ref;
  if (s <> '') and (s[1] = '#') then Delete(s, 1, 1);
  if s = '' then Exit;
  if Ids.Find(s, i) then Result := TDOMElement(Ids.Objects[i]);
end;

procedure TSvgReader.ParseCss(const Text: string);
var
  t, sel, body, one: string;
  p, ob, cb, i, k, n: Integer;
  sels: TStringArray;
  r: TCssRule;

  procedure ParseSelector(const S: string);
  var
    j, st: Integer;
    cur: string;
    kind: Char;

    procedure Flush;
    begin
      if cur = '' then Exit;
      case kind of
        't': r.Tag := LowerCase(cur);
        '.': begin SetLength(r.Classes, Length(r.Classes) + 1); r.Classes[High(r.Classes)] := cur; end;
        '#': r.Id := cur;
      end;
      cur := '';
    end;

  begin
    r := Default(TCssRule);
    cur := ''; kind := 't';
    st := 1;
    for j := st to Length(S) do
      case S[j] of
        '.', '#': begin Flush; kind := S[j]; end;
        '*': ;
      else
        cur := cur + S[j];
      end;
    Flush;
  end;

begin
  // drop comments
  t := Text;
  while Pos('/*', t) > 0 do
  begin
    p := Pos('/*', t);
    k := Pos('*/', Copy(t, p + 2, MaxInt));
    if k = 0 then Delete(t, p, MaxInt) else Delete(t, p, k + 3);
  end;
  p := 1;
  n := Length(Css);
  while p <= Length(t) do
  begin
    ob := Pos('{', Copy(t, p, MaxInt));
    if ob = 0 then Break;
    ob := p + ob - 1;
    cb := Pos('}', Copy(t, ob + 1, MaxInt));
    if cb = 0 then Break;
    cb := ob + cb;
    sel := Trim(Copy(t, p, ob - p));
    body := Trim(Copy(t, ob + 1, cb - ob - 1));
    p := cb + 1;
    if (sel = '') or (sel[1] = '@') then Continue;
    sels := sel.Split([',']);
    for i := 0 to High(sels) do
    begin
      one := Trim(sels[i]);
      // only simple selectors (a descendant / child selector applies to its last part)
      if LastDelimiter(' >+~', one) > 0 then one := Copy(one, LastDelimiter(' >+~', one) + 1, MaxInt);
      if (Pos(':', one) > 0) or (Pos('[', one) > 0) then Continue;
      ParseSelector(one);
      r.Spec := Ord(r.Id <> '') * 100 + Length(r.Classes) * 10 + Ord(r.Tag <> '');
      r.Order := n;
      r.Body := body;
      SetLength(Css, n + 1);
      Css[n] := r;
      Inc(n);
    end;
  end;
end;

procedure TSvgReader.CollectCss(N: TDOMNode);
var c: TDOMNode; s: string;
begin
  if (N is TDOMElement) and (ElemName(N) = 'style') then
  begin
    s := '';
    c := N.FirstChild;
    while c <> nil do
    begin
      if (c.NodeType = TEXT_NODE) or (c.NodeType = CDATA_SECTION_NODE) then s := s + UTF8Encode(c.NodeValue);
      c := c.NextSibling;
    end;
    ParseCss(s);
    Exit;
  end;
  c := N.FirstChild;
  while c <> nil do
  begin
    CollectCss(c);
    c := c.NextSibling;
  end;
end;

function TSvgReader.Len(const S: string; Ref, FontSize: Double; Def: Double): Double;
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
  if u = '' then Result := v
  else if u = 'px' then Result := v
  else if u = 'pt' then Result := v * 96 / 72
  else if u = 'pc' then Result := v * 16
  else if u = 'mm' then Result := v * 96 / 25.4
  else if u = 'cm' then Result := v * 96 / 2.54
  else if u = 'in' then Result := v * 96
  else if u = 'em' then Result := v * FontSize
  else if u = 'ex' then Result := v * FontSize / 2
  else if u = '%' then Result := v * Ref / 100
  else Result := v;
end;

function TSvgReader.LenX(E: TDOMNode; const Name: string; const Ctx: TSvgCtx; const St: TSvgStyle; Def: Double): Double;
begin
  Result := Len(Attr(E, Name), Ctx.VW, St.FontSize, Def);
end;

function TSvgReader.LenY(E: TDOMNode; const Name: string; const Ctx: TSvgCtx; const St: TSvgStyle; Def: Double): Double;
begin
  Result := Len(Attr(E, Name), Ctx.VH, St.FontSize, Def);
end;

function TSvgReader.LenD(E: TDOMNode; const Name: string; const Ctx: TSvgCtx; const St: TSvgStyle; Def: Double): Double;
begin
  Result := Len(Attr(E, Name), Sqrt((Sqr(Ctx.VW) + Sqr(Ctx.VH)) / 2), St.FontSize, Def);
end;

function DefaultStyle: TSvgStyle;
begin
  Result := Default(TSvgStyle);
  Result.Fill := 'black';
  Result.Stroke := 'none';
  Result.FillOpacity := 1;
  Result.StrokeOpacity := 1;
  Result.FillRule := frNonZero;
  Result.ClipRule := frNonZero;
  Result.StrokeWidth := 1;
  Result.LineCap := lcButt;
  Result.LineJoin := ljMiter;
  Result.MiterLimit := 4;
  Result.Color := XV_BLACK;
  Result.FontFamily := 'sans-serif';
  Result.FontSize := 16;
  Result.FontWeight := 400;
  Result.Visible := True;
  Result.Opacity := 1;
  Result.Display := True;
  Result.StopColor := 'black';
  Result.StopOpacity := 1;
end;

procedure TSvgReader.ApplyProp(var St: TSvgStyle; const Name, Value: string; const Parent: TSvgStyle);
var
  n, v, lv: string;
  c: TXVColor;
begin
  n := LowerCase(Trim(Name));
  v := Trim(Value);
  if (Length(v) > 10) and (LowerCase(Copy(v, Length(v) - 9, 10)) = '!important') then v := Trim(Copy(v, 1, Length(v) - 10));
  lv := LowerCase(v);
  if lv = 'inherit' then
  begin
    if n = 'fill' then St.Fill := Parent.Fill
    else if n = 'stroke' then St.Stroke := Parent.Stroke
    else if n = 'opacity' then St.Opacity := Parent.Opacity
    else if n = 'color' then St.Color := Parent.Color;
    Exit;
  end;
  if n = 'fill' then St.Fill := v
  else if n = 'stroke' then St.Stroke := v
  else if n = 'fill-opacity' then St.FillOpacity := EnsureRange(Len(v, 1, 1, 1), 0, 1)
  else if n = 'stroke-opacity' then St.StrokeOpacity := EnsureRange(Len(v, 1, 1, 1), 0, 1)
  else if n = 'opacity' then St.Opacity := EnsureRange(Len(v, 1, 1, 1), 0, 1)
  else if n = 'fill-rule' then begin if lv = 'evenodd' then St.FillRule := frEvenOdd else St.FillRule := frNonZero; end
  else if n = 'clip-rule' then begin if lv = 'evenodd' then St.ClipRule := frEvenOdd else St.ClipRule := frNonZero; end
  else if n = 'stroke-width' then St.StrokeWidth := Max(0, Len(v, 100, St.FontSize, 1))
  else if n = 'vector-effect' then St.NonScaling := lv = 'non-scaling-stroke'
  else if n = 'stroke-linecap' then
  begin
    if lv = 'round' then St.LineCap := lcRound else if lv = 'square' then St.LineCap := lcSquare else St.LineCap := lcButt;
  end
  else if n = 'stroke-linejoin' then
  begin
    if lv = 'round' then St.LineJoin := ljRound else if lv = 'bevel' then St.LineJoin := ljBevel else St.LineJoin := ljMiter;
  end
  else if n = 'stroke-miterlimit' then St.MiterLimit := Max(1, XVStrToFloat(v, 4))
  else if n = 'stroke-dasharray' then St.DashArray := v
  else if n = 'stroke-dashoffset' then St.DashOffset := Len(v, 100, St.FontSize, 0)
  else if n = 'color' then begin if XVParseCssColor(v, c, Parent.Color) then St.Color := c; end
  else if n = 'font-family' then St.FontFamily := v
  else if n = 'font-size' then
  begin
    if lv = 'xx-small' then St.FontSize := 9
    else if lv = 'x-small' then St.FontSize := 10
    else if lv = 'small' then St.FontSize := 13
    else if lv = 'medium' then St.FontSize := 16
    else if lv = 'large' then St.FontSize := 18
    else if lv = 'x-large' then St.FontSize := 24
    else if lv = 'xx-large' then St.FontSize := 32
    else if lv = 'larger' then St.FontSize := Parent.FontSize * 1.2
    else if lv = 'smaller' then St.FontSize := Parent.FontSize / 1.2
    else St.FontSize := Max(0.01, Len(v, Parent.FontSize, Parent.FontSize, 16));
  end
  else if n = 'font-weight' then
  begin
    if lv = 'bold' then St.FontWeight := 700
    else if lv = 'bolder' then St.FontWeight := Min(900, Parent.FontWeight + 300)
    else if lv = 'lighter' then St.FontWeight := Max(100, Parent.FontWeight - 300)
    else if lv = 'normal' then St.FontWeight := 400
    else St.FontWeight := EnsureRange(StrToIntDef(lv, 400), 100, 900);
  end
  else if n = 'font-style' then St.Italic := (lv = 'italic') or (lv = 'oblique')
  else if n = 'font' then
  begin
    // shorthand: style weight size family
    if Pos('italic', lv) > 0 then St.Italic := True;
    if Pos('bold', lv) > 0 then St.FontWeight := 700;
  end
  else if n = 'text-decoration' then St.Decoration := lv
  else if n = 'text-anchor' then
  begin
    if lv = 'middle' then St.Anchor := taMiddle else if lv = 'end' then St.Anchor := taEnd else St.Anchor := taStart;
  end
  else if (n = 'dominant-baseline') or (n = 'alignment-baseline') then
  begin
    if (lv = 'hanging') or (lv = 'text-before-edge') or (lv = 'text-top') then St.Baseline := tbTop
    else if (lv = 'middle') or (lv = 'central') then St.Baseline := tbMiddle
    else if (lv = 'text-after-edge') or (lv = 'ideographic') or (lv = 'text-bottom') then St.Baseline := tbBottom
    else St.Baseline := tbAlphabetic;
  end
  else if n = 'visibility' then St.Visible := (lv <> 'hidden') and (lv <> 'collapse')
  else if n = 'display' then St.Display := lv <> 'none'
  else if n = 'clip-path' then St.ClipPath := v
  else if n = 'stop-color' then St.StopColor := v
  else if n = 'stop-opacity' then St.StopOpacity := EnsureRange(Len(v, 1, 1, 1), 0, 1)
  else if n = 'marker' then begin St.MarkerStart := v; St.MarkerMid := v; St.MarkerEnd := v; end
  else if n = 'marker-start' then St.MarkerStart := v
  else if n = 'marker-mid' then St.MarkerMid := v
  else if n = 'marker-end' then St.MarkerEnd := v;
end;

procedure TSvgReader.ApplyDecls(var St: TSvgStyle; const Decls: string; const Parent: TSvgStyle);
var
  parts: TStringArray;
  i, p: Integer;
begin
  parts := Decls.Split([';']);
  for i := 0 to High(parts) do
  begin
    p := Pos(':', parts[i]);
    if p > 0 then ApplyProp(St, Copy(parts[i], 1, p - 1), Copy(parts[i], p + 1, MaxInt), Parent);
  end;
end;

const
  PRES_ATTRS: array[0..34] of string = ('vector-effect', 'fill', 'stroke', 'fill-opacity', 'stroke-opacity', 'opacity', 'fill-rule',
    'clip-rule', 'stroke-width', 'stroke-linecap', 'stroke-linejoin', 'stroke-miterlimit', 'stroke-dasharray',
    'stroke-dashoffset', 'color', 'font-family', 'font-size', 'font-weight', 'font-style', 'text-decoration',
    'text-anchor', 'dominant-baseline', 'alignment-baseline', 'visibility', 'display', 'clip-path', 'stop-color',
    'stop-opacity', 'marker', 'marker-start', 'marker-mid', 'marker-end', 'font', 'letter-spacing', 'word-spacing');

function TSvgReader.ComputeStyle(E: TDOMElement; const Parent: TSvgStyle): TSvgStyle;
var
  i, j, k: Integer;
  tag, id, cls: string;
  classes: TStringArray;
  match: Boolean;
  idx: array of Integer;
  t: Integer;
begin
  Result := Parent;
  // not inherited
  Result.Opacity := 1;
  Result.Display := True;
  Result.NonScaling := False;
  Result.ClipPath := '';
  Result.StopColor := 'black';
  Result.StopOpacity := 1;
  for i := 0 to High(PRES_ATTRS) do
    if HasAttr(E, PRES_ATTRS[i]) then ApplyProp(Result, PRES_ATTRS[i], Attr(E, PRES_ATTRS[i]), Parent);
  if Length(Css) > 0 then
  begin
    tag := ElemName(E);
    id := Attr(E, 'id');
    cls := Attr(E, 'class');
    classes := SplitArgs(cls);
    idx := nil;
    for i := 0 to High(Css) do
    begin
      match := True;
      if (Css[i].Tag <> '') and (Css[i].Tag <> tag) then match := False;
      if match and (Css[i].Id <> '') and (Css[i].Id <> id) then match := False;
      if match then
        for j := 0 to High(Css[i].Classes) do
        begin
          match := False;
          for k := 0 to High(classes) do
            if classes[k] = Css[i].Classes[j] then begin match := True; Break; end;
          if not match then Break;
        end;
      if match and (Css[i].Tag = '') and (Css[i].Id = '') and (Length(Css[i].Classes) = 0) then
        match := True;     // universal selector
      if match then
      begin
        SetLength(idx, Length(idx) + 1);
        idx[High(idx)] := i;
      end;
    end;
    // by specificity, then source order
    for i := 1 to High(idx) do
    begin
      t := idx[i]; j := i - 1;
      while (j >= 0) and ((Css[idx[j]].Spec > Css[t].Spec) or
            ((Css[idx[j]].Spec = Css[t].Spec) and (Css[idx[j]].Order > Css[t].Order))) do
      begin
        idx[j + 1] := idx[j];
        Dec(j);
      end;
      idx[j + 1] := t;
    end;
    for i := 0 to High(idx) do ApplyDecls(Result, Css[idx[i]].Body, Parent);
  end;
  if HasAttr(E, 'style') then ApplyDecls(Result, Attr(E, 'style'), Parent);
end;

// ------------------------------ paints -------------------------------------

function TSvgReader.PatternColor(E: TDOMElement; const St: TSvgStyle): TXVColor;
var
  c: TDOMNode;
  s: TSvgStyle;
  col: TXVColor;
  h: TDOMElement;
begin
  Result := $FF808080;
  // the first painted child of the pattern (or of the pattern it inherits)
  h := E;
  while h <> nil do
  begin
    c := h.FirstChild;
    while c <> nil do
    begin
      if c is TDOMElement then
      begin
        s := ComputeStyle(TDOMElement(c), St);
        if (LowerCase(s.Fill) <> 'none') and XVParseCssColor(s.Fill, col, s.Color) then Exit(col);
        if (LowerCase(s.Stroke) <> 'none') and XVParseCssColor(s.Stroke, col, s.Color) then Exit(col);
      end;
      c := c.NextSibling;
    end;
    if Href(h) = '' then Break;
    h := FindId(Href(h));
    if h = E then Break;
  end;
end;

function TSvgReader.MakeGradient(E: TDOMElement; Opacity: Double; const St: TSvgStyle; const UserBox: TXVRect;
  const CTM: TXVMatrix; out AvgColor: TXVColor): Integer;
var
  G: TXVGradient;
  chain: array of TDOMElement;
  h: TDOMElement;
  i, n: Integer;
  units, sp, gt: string;
  bbox: Boolean;
  stopsFrom: TDOMElement;
  c: TDOMNode;
  ss: TSvgStyle;
  col: TXVColor;
  off, lastOff: Double;
  m: TXVMatrix;
  r, g2, b, a: Integer;
  vw, vh: Double;

  function A_(const Name: string): string;
  var k: Integer;
  begin
    // the first element of the href chain that has the attribute
    for k := 0 to High(chain) do
      if HasAttr(chain[k], Name) then Exit(Attr(chain[k], Name));
    Result := '';
  end;

  function Coord(const Name, Def: string; Ref: Double): Double;
  var v: string;
  begin
    v := A_(Name);
    if v = '' then v := Def;
    if bbox then
    begin
      if (v <> '') and (v[Length(v)] = '%') then Result := XVStrToFloat(Copy(v, 1, Length(v) - 1), 0) / 100
      else Result := XVStrToFloat(v, 0);
    end
    else Result := Len(v, Ref, St.FontSize, 0);
  end;

begin
  Result := -1;
  AvgColor := XV_BLACK;
  chain := nil;
  h := E;
  while (h <> nil) and (Length(chain) < 16) do
  begin
    SetLength(chain, Length(chain) + 1);
    chain[High(chain)] := h;
    if Href(h) = '' then Break;
    h := FindId(Href(h));
  end;
  G := Default(TXVGradient);
  if ElemName(E) = 'radialgradient' then G.Kind := gkRadial else G.Kind := gkLinear;
  units := A_('gradientUnits');
  bbox := units <> 'userSpaceOnUse';
  sp := A_('spreadMethod');
  if sp = 'reflect' then G.Spread := spReflect else if sp = 'repeat' then G.Spread := spRepeat else G.Spread := spPad;
  vw := Doc.Width; vh := Doc.Height;
  if vw <= 0 then vw := 100;
  if vh <= 0 then vh := 100;
  if G.Kind = gkLinear then
  begin
    G.X1 := Coord('x1', '0%', vw); G.Y1 := Coord('y1', '0%', vh);
    G.X2 := Coord('x2', '100%', vw); G.Y2 := Coord('y2', '0%', vh);
  end
  else
  begin
    G.CX := Coord('cx', '50%', vw); G.CY := Coord('cy', '50%', vh);
    G.R := Coord('r', '50%', Sqrt((vw * vw + vh * vh) / 2));
    if A_('fx') <> '' then G.FX := Coord('fx', '50%', vw) else G.FX := G.CX;
    if A_('fy') <> '' then G.FY := Coord('fy', '50%', vh) else G.FY := G.CY;
  end;
  gt := A_('gradientTransform');
  m := CTM;
  if bbox then
  begin
    if (UserBox.Width <= 0) or (UserBox.Height <= 0) then
    begin
      // a degenerate box (a horizontal line): objectBoundingBox paints nothing,
      // the last stop's colour is the best guess
    end;
    m := XVMul(m, TXVMatrix.Make(Max(UserBox.Width, 1e-9), 0, 0, Max(UserBox.Height, 1e-9), UserBox.Left, UserBox.Top));
  end;
  if gt <> '' then m := XVMul(m, ParseTransformList(gt));
  G.Matrix := m;
  // stops: from the first element of the chain that has any
  stopsFrom := nil;
  for i := 0 to High(chain) do
  begin
    c := chain[i].FirstChild;
    while c <> nil do
    begin
      if (c is TDOMElement) and (ElemName(c) = 'stop') then begin stopsFrom := chain[i]; Break; end;
      c := c.NextSibling;
    end;
    if stopsFrom <> nil then Break;
  end;
  if stopsFrom = nil then Exit;
  n := 0;
  lastOff := 0;
  r := 0; g2 := 0; b := 0; a := 0;
  c := stopsFrom.FirstChild;
  while c <> nil do
  begin
    if (c is TDOMElement) and (ElemName(c) = 'stop') then
    begin
      ss := ComputeStyle(TDOMElement(c), St);
      if not XVParseCssColor(ss.StopColor, col, ss.Color) then col := XV_BLACK;
      col := XVMulAlpha(col, ss.StopOpacity * Opacity);
      if Attr(c, 'offset') = '' then off := lastOff
      else if Pos('%', Attr(c, 'offset')) > 0 then off := XVStrToFloat(StringReplace(Attr(c, 'offset'), '%', '', []), 0) / 100
      else off := XVStrToFloat(Attr(c, 'offset'), 0);
      off := EnsureRange(off, 0, 1);
      if off < lastOff then off := lastOff;
      lastOff := off;
      SetLength(G.Stops, n + 1);
      G.Stops[n].Offset := off;
      G.Stops[n].Color := col;
      Inc(r, XVColorR(col)); Inc(g2, XVColorG(col)); Inc(b, XVColorB(col)); Inc(a, XVColorAlpha(col));
      Inc(n);
    end;
    c := c.NextSibling;
  end;
  if n = 0 then Exit;
  AvgColor := XVRGBA(r div n, g2 div n, b div n, a div n);
  if n = 1 then
  begin
    AvgColor := G.Stops[0].Color;
    Exit(-2);              // one stop: a solid colour
  end;
  if bbox and ((UserBox.Width <= 0) or (UserBox.Height <= 0)) then
  begin
    AvgColor := G.Stops[n - 1].Color;
    Exit(-2);
  end;
  Result := Doc.AddGradient(G);
end;

function TSvgReader.ResolvePaint(const V: string; Opacity: Double; const St: TSvgStyle; const UserBox: TXVRect;
  const CTM: TXVMatrix): TXVPaint;
var
  lv, fb: string;
  c: TXVColor;
  e: TDOMElement;
  gi: Integer;
  avg: TXVColor;
begin
  Result := XVNoPaint;
  lv := LowerCase(Trim(V));
  if (lv = '') or (lv = 'none') then Exit;
  if Copy(lv, 1, 4) = 'url(' then
  begin
    e := FindId(UrlId(V));
    if e <> nil then
    begin
      if (ElemName(e) = 'lineargradient') or (ElemName(e) = 'radialgradient') then
      begin
        gi := MakeGradient(e, Opacity, St, UserBox, CTM, avg);
        if gi >= 0 then Exit(XVGradientPaint(gi, avg));
        if gi = -2 then Exit(XVSolid(avg));
        Exit;
      end;
      if ElemName(e) = 'pattern' then
        Exit(XVSolid(XVMulAlpha(PatternColor(e, St), Opacity)));
    end;
    fb := UrlFallback(V);
    if (fb <> '') and (LowerCase(fb) <> 'none') and XVParseCssColor(fb, c, St.Color) then
      Exit(XVSolid(XVMulAlpha(c, Opacity)));
    Exit;
  end;
  if XVParseCssColor(V, c, St.Color) then Result := XVSolid(XVMulAlpha(c, Opacity))
  else Result := XVSolid(XVMulAlpha(XV_BLACK, Opacity));
  if Result.Color shr 24 = 0 then Result := XVNoPaint;
end;

// ------------------------------ shapes -------------------------------------

function TSvgReader.ShapePath(E: TDOMElement; const Ctx: TSvgCtx; const St: TSvgStyle; out P: TXVPath): Boolean;
var
  n: string;
  x, y, w, h, rx, ry, cx, cy, r: Double;
  a: TStringArray;
  i: Integer;
  hasRx, hasRy: Boolean;
begin
  P := Default(TXVPath);
  P.Clear;
  n := ElemName(E);
  if n = 'path' then XVParseSvgPathData(Attr(E, 'd'), P)
  else if n = 'rect' then
  begin
    x := LenX(E, 'x', Ctx, St); y := LenY(E, 'y', Ctx, St);
    w := LenX(E, 'width', Ctx, St); h := LenY(E, 'height', Ctx, St);
    if (w <= 0) or (h <= 0) then Exit(False);
    hasRx := HasAttr(E, 'rx') and (LowerCase(Attr(E, 'rx')) <> 'auto');
    hasRy := HasAttr(E, 'ry') and (LowerCase(Attr(E, 'ry')) <> 'auto');
    rx := LenX(E, 'rx', Ctx, St); ry := LenY(E, 'ry', Ctx, St);
    if hasRx and not hasRy then ry := rx;
    if hasRy and not hasRx then rx := ry;
    if (rx > 0) and (ry > 0) then P.AddRoundRect(x, y, w, h, rx, ry) else P.AddRect(x, y, w, h);
  end
  else if n = 'circle' then
  begin
    cx := LenX(E, 'cx', Ctx, St); cy := LenY(E, 'cy', Ctx, St); r := LenD(E, 'r', Ctx, St);
    if r <= 0 then Exit(False);
    P.AddEllipse(cx, cy, r, r);
  end
  else if n = 'ellipse' then
  begin
    cx := LenX(E, 'cx', Ctx, St); cy := LenY(E, 'cy', Ctx, St);
    rx := LenX(E, 'rx', Ctx, St); ry := LenY(E, 'ry', Ctx, St);
    if (LowerCase(Attr(E, 'rx')) = 'auto') or not HasAttr(E, 'rx') then rx := ry;
    if (LowerCase(Attr(E, 'ry')) = 'auto') or not HasAttr(E, 'ry') then ry := rx;
    if (rx <= 0) or (ry <= 0) then Exit(False);
    P.AddEllipse(cx, cy, rx, ry);
  end
  else if n = 'line' then
  begin
    P.MoveTo(LenX(E, 'x1', Ctx, St), LenY(E, 'y1', Ctx, St));
    P.LineTo(LenX(E, 'x2', Ctx, St), LenY(E, 'y2', Ctx, St));
  end
  else if (n = 'polyline') or (n = 'polygon') then
  begin
    a := SplitArgs(StringReplace(Attr(E, 'points'), '-', ' -', [rfReplaceAll]));
    for i := 0 to Length(a) div 2 - 1 do
      if i = 0 then P.MoveTo(XVStrToFloat(a[0]), XVStrToFloat(a[1]))
      else P.LineTo(XVStrToFloat(a[2 * i]), XVStrToFloat(a[2 * i + 1]));
    if n = 'polygon' then P.Close;
  end
  else Exit(False);
  Result := P.NCmd > 0;
end;

function TSvgReader.BuildClip(const Ref: string; const Ctx: TSvgCtx; const UserBox: TXVRect): Integer;
var
  e: TDOMElement;
  c: TDOMNode;
  all, one: TXVPath;
  m, cm: TXVMatrix;
  s, base: TSvgStyle;
  rule: TXVFillRule;
  cnt: Integer;
  cctx: TSvgCtx;
begin
  Result := -1;
  e := FindId(UrlId(Ref));
  if (e = nil) or (ElemName(e) <> 'clippath') then Exit;
  m := Ctx.CTM;
  if Attr(e, 'clipPathUnits') = 'objectBoundingBox' then
    m := XVMul(m, TXVMatrix.Make(UserBox.Width, 0, 0, UserBox.Height, UserBox.Left, UserBox.Top));
  m := XVMul(m, ParseTransformList(Attr(e, 'transform')));
  all := Default(TXVPath);
  all.Clear;
  rule := frNonZero;
  cnt := 0;
  base := ComputeStyle(e, DefaultStyle);
  c := e.FirstChild;
  while c <> nil do
  begin
    if c is TDOMElement then
    begin
      s := ComputeStyle(TDOMElement(c), base);
      if s.Display and s.Visible then
      begin
        if ElemName(c) = 'use' then
        begin
          // a <use> of a shape inside the clip path
          cm := XVMul(m, ParseTransformList(Attr(c, 'transform')));
          cm := XVMul(cm, TXVMatrix.Translate(XVStrToFloat(Attr(c, 'x')), XVStrToFloat(Attr(c, 'y'))));
          if FindId(Href(c)) <> nil then
          begin
            cctx := Ctx;
            cctx.CTM := cm;
            s := ComputeStyle(FindId(Href(c)), s);
            if ShapePath(FindId(Href(c)), cctx, s, one) then
            begin
              one.Transform(XVMul(cm, ParseTransformList(Attr(FindId(Href(c)), 'transform'))));
              all.Append(one);
              rule := s.ClipRule;
              Inc(cnt);
            end;
          end;
        end
        else if ShapePath(TDOMElement(c), Ctx, s, one) then
        begin
          one.Transform(XVMul(m, ParseTransformList(Attr(c, 'transform'))));
          all.Append(one);
          rule := s.ClipRule;
          Inc(cnt);
        end;
      end;
    end;
    c := c.NextSibling;
  end;
  if cnt > 1 then rule := frNonZero;
  if all.NCmd = 0 then
  begin
    // an empty clip path hides everything
    all.AddRect(0, 0, 0, 0);
  end;
  Result := Doc.AddClip(all, rule);
end;

procedure TSvgReader.EmitMarkers(const UserPath: TXVPath; const Ctx: TSvgCtx; const St: TSvgStyle);
type
  TVert = record
    X, Y, InAng, OutAng: Double;
    HasIn, HasOut: Boolean;
  end;
var
  verts: array of TVert;
  i, k, nv: Integer;
  px, py, sx, sy: Double;

  procedure AddVert(x, y: Double);
  begin
    SetLength(verts, nv + 1);
    verts[nv] := Default(TVert);
    verts[nv].X := x; verts[nv].Y := y;
    Inc(nv);
  end;

  procedure Place(const Ref: string; const V: TVert; IsStart: Boolean);
  var
    e: TDOMElement;
    m: TXVMatrix;
    ang, mw, mh, rx, ry, sw: Double;
    orient: string;
    ok: Boolean;
    cctx: TSvgCtx;
    ms: TSvgStyle;
  begin
    if (Ref = '') or (LowerCase(Ref) = 'none') then Exit;
    e := FindId(UrlId(Ref));
    if (e = nil) or (ElemName(e) <> 'marker') then Exit;
    orient := LowerCase(Attr(e, 'orient'));
    ang := 0;
    if (orient = 'auto') or (orient = 'auto-start-reverse') then
    begin
      if V.HasIn and V.HasOut then
      begin
        ang := (V.InAng + V.OutAng) / 2;
        if Abs(V.InAng - V.OutAng) > Pi then ang := ang + Pi;
      end
      else if V.HasIn then ang := V.InAng
      else ang := V.OutAng;
      if (orient = 'auto-start-reverse') and IsStart then ang := ang + Pi;
    end
    else ang := DegToRad(XVStrToFloat(orient, 0));
    mw := Len(Attr(e, 'markerWidth'), 100, St.FontSize, 3);
    mh := Len(Attr(e, 'markerHeight'), 100, St.FontSize, 3);
    rx := XVStrToFloat(Attr(e, 'refX'), 0); ry := XVStrToFloat(Attr(e, 'refY'), 0);
    sw := 1;
    if Attr(e, 'markerUnits') <> 'userSpaceOnUse' then sw := St.StrokeWidth;
    m := XVMul(Ctx.CTM, TXVMatrix.Translate(V.X, V.Y));
    m := XVMul(m, TXVMatrix.Rotate(ang));
    m := XVMul(m, TXVMatrix.Scale(sw, sw));
    if Attr(e, 'viewBox') <> '' then
    begin
      m := XVMul(m, ViewBoxMatrix(Attr(e, 'viewBox'), Attr(e, 'preserveAspectRatio'), 0, 0, mw, mh, ok));
      // refX / refY are in the viewBox space
    end;
    m := XVMul(m, TXVMatrix.Translate(-rx, -ry));
    cctx := Ctx;
    cctx.CTM := m;
    ms := ComputeStyle(e, DefaultStyle);
    ms.FontSize := St.FontSize;
    Inc(Depth);
    if Depth < 40 then Children(e, cctx, ms);
    Dec(Depth);
  end;

begin
  if ((St.MarkerStart = '') or (LowerCase(St.MarkerStart) = 'none')) and
     ((St.MarkerMid = '') or (LowerCase(St.MarkerMid) = 'none')) and
     ((St.MarkerEnd = '') or (LowerCase(St.MarkerEnd) = 'none')) then Exit;
  nv := 0;
  verts := nil;
  k := 0;
  px := 0; py := 0; sx := 0; sy := 0;
  for i := 0 to UserPath.NCmd - 1 do
    case UserPath.Cmds[i] of
      pcMoveTo:
        begin
          px := UserPath.Pts[k].X; py := UserPath.Pts[k].Y; sx := px; sy := py;
          AddVert(px, py);
          Inc(k);
        end;
      pcLineTo:
        begin
          if nv > 0 then
          begin
            verts[nv - 1].OutAng := ArcTan2(UserPath.Pts[k].Y - py, UserPath.Pts[k].X - px);
            verts[nv - 1].HasOut := True;
          end;
          AddVert(UserPath.Pts[k].X, UserPath.Pts[k].Y);
          verts[nv - 1].InAng := ArcTan2(UserPath.Pts[k].Y - py, UserPath.Pts[k].X - px);
          verts[nv - 1].HasIn := True;
          px := UserPath.Pts[k].X; py := UserPath.Pts[k].Y;
          Inc(k);
        end;
      pcCubicTo:
        begin
          if nv > 0 then
          begin
            verts[nv - 1].OutAng := ArcTan2(UserPath.Pts[k].Y - py, UserPath.Pts[k].X - px);
            verts[nv - 1].HasOut := True;
          end;
          AddVert(UserPath.Pts[k + 2].X, UserPath.Pts[k + 2].Y);
          verts[nv - 1].InAng := ArcTan2(UserPath.Pts[k + 2].Y - UserPath.Pts[k + 1].Y,
            UserPath.Pts[k + 2].X - UserPath.Pts[k + 1].X);
          verts[nv - 1].HasIn := True;
          px := UserPath.Pts[k + 2].X; py := UserPath.Pts[k + 2].Y;
          Inc(k, 3);
        end;
      pcClose:
        begin
          px := sx; py := sy;
        end;
    end;
  if nv = 0 then Exit;
  Place(St.MarkerStart, verts[0], True);
  for i := 1 to nv - 2 do Place(St.MarkerMid, verts[i], False);
  if nv > 1 then Place(St.MarkerEnd, verts[nv - 1], False);
end;

procedure TSvgReader.EmitShape(E: TDOMElement; const Ctx: TSvgCtx; const St: TSvgStyle);
var
  P, U: TXVPath;
  box: TXVRect;
  fill: TXVPaint;
  stroke: TXVStroke;
  sc: Double;
  a: TStringArray;
  i, n: Integer;
  total: Double;
  isLine: Boolean;
begin
  if not ShapePath(E, Ctx, St, P) then Exit;
  U := P.Copy;
  if not P.Bounds(box) then Exit;
  isLine := ElemName(E) = 'line';
  if isLine then fill := XVNoPaint
  else fill := ResolvePaint(St.Fill, St.FillOpacity, St, box, Ctx.CTM);
  stroke := XVNoStroke;
  stroke.Paint := ResolvePaint(St.Stroke, St.StrokeOpacity, St, box, Ctx.CTM);
  sc := Ctx.CTM.ScaleFactor;
  stroke.Width := St.StrokeWidth * sc;
  // a non-scaling stroke of one pixel or less: a hairline
  if St.NonScaling and (St.StrokeWidth <= 1) then stroke.Width := 0;
  stroke.Cap := St.LineCap;
  stroke.Join := St.LineJoin;
  stroke.MiterLimit := St.MiterLimit;
  if St.StrokeWidth <= 0 then stroke.Paint := XVNoPaint;
  if (St.DashArray <> '') and (LowerCase(St.DashArray) <> 'none') then
  begin
    a := SplitArgs(St.DashArray);
    n := Length(a);
    if Odd(n) then SetLength(stroke.Dashes, 2 * n) else SetLength(stroke.Dashes, n);
    total := 0;
    for i := 0 to High(stroke.Dashes) do
    begin
      stroke.Dashes[i] := Max(0, Len(a[i mod n], 100, St.FontSize, 0)) * sc;
      total := total + stroke.Dashes[i];
    end;
    if total <= 0 then stroke.Dashes := nil;
    stroke.DashOffset := St.DashOffset * sc;
  end;
  if St.Visible then
  begin
    P.Transform(Ctx.CTM);
    Doc.AddPath(P, fill, stroke, St.FillRule, 1);
  end;
  EmitMarkers(U, Ctx, St);
end;

// ------------------------------ text ---------------------------------------

function CollapseSpaces(const S: string; Preserve: Boolean): string;
var
  i: Integer;
  sp: Boolean;
begin
  Result := '';
  sp := False;
  for i := 1 to Length(S) do
    if S[i] in [#9, #10, #13, ' '] then
    begin
      if Preserve then Result := Result + ' '
      else if not sp then Result := Result + ' ';
      sp := True;
    end
    else
    begin
      Result := Result + S[i];
      sp := False;
    end;
end;

function FontFamilyName(const S: string): string;
var t: string; p: Integer;
begin
  t := Trim(S);
  p := Pos(',', t);
  if p > 0 then t := Trim(Copy(t, 1, p - 1));
  if (Length(t) >= 2) and (t[1] in ['''', '"']) then t := Copy(t, 2, Length(t) - 2);
  Result := t;
  t := LowerCase(t);
  if (t = '') or (t = 'sans-serif') or (t = 'sans') then Result := 'Arial'
  else if t = 'serif' then Result := 'Times New Roman'
  else if t = 'monospace' then Result := 'Courier New'
  else if t = 'cursive' then Result := 'Comic Sans MS'
  else if t = 'fantasy' then Result := 'Impact';
end;

procedure TSvgReader.EmitText(E: TDOMElement; const Ctx: TSvgCtx; const St: TSvgStyle);
type
  TPos = record
    Has: Boolean;
    V: Double;
  end;
var
  preserve: Boolean;
  penSet: Boolean;
  first: Boolean;
  pendingDY: Double;
  textX, textY: Double;
  lastIdx: Integer;
  trailingSpace: Boolean;

  function PosList(N: TDOMNode; const Name: string; IsX: Boolean): TXVDoubles;
  var a: TStringArray; i: Integer;
  begin
    a := SplitArgs(Attr(N, Name));
    SetLength(Result, Length(a));
    for i := 0 to High(a) do
      if IsX then Result[i] := Len(a[i], Ctx.VW, St.FontSize, 0) else Result[i] := Len(a[i], Ctx.VH, St.FontSize, 0);
  end;

  procedure Emit(const S: string; const RS: TSvgStyle; AbsX, AbsY: TPos; DX, DY: Double; Rot: Double);
  var
    font: TXVFont;
    m: TXVMatrix;
    idx: Integer;
    fill: TXVPaint;
    stroke: TXVStroke;
    box: TXVRect;
    cont: Boolean;
  begin
    if S = '' then Exit;
    font := XVDefaultFont;
    font.Family := FontFamilyName(RS.FontFamily);
    font.Size := RS.FontSize;
    font.Weight := RS.FontWeight;
    font.Italic := RS.Italic;
    font.Underline := Pos('underline', RS.Decoration) > 0;
    font.Strike := Pos('line-through', RS.Decoration) > 0;
    cont := not (AbsX.Has or AbsY.Has) and not first;
    if AbsX.Has then textX := AbsX.V;
    if AbsY.Has then textY := AbsY.V;
    box := XVRect(textX, textY - RS.FontSize, textX + RS.FontSize * Length(S) * 0.5, textY);
    fill := ResolvePaint(RS.Fill, RS.FillOpacity, RS, box, Ctx.CTM);
    stroke := XVNoStroke;
    stroke.Paint := ResolvePaint(RS.Stroke, RS.StrokeOpacity, RS, box, Ctx.CTM);
    stroke.Width := RS.StrokeWidth * Ctx.CTM.ScaleFactor;
    if cont then
    begin
      // continues after the previous run: the translation is the shift only
      m := Ctx.CTM;
      m.E := Ctx.CTM.ApplyVec(DX, DY).X;
      m.F := Ctx.CTM.ApplyVec(DX, DY).Y;
    end
    else
    begin
      textX := textX + DX; textY := textY + DY;
      m := XVMul(Ctx.CTM, TXVMatrix.Translate(textX, textY));
    end;
    if Rot <> 0 then m := XVMul(m, TXVMatrix.Rotate(DegToRad(Rot)));
    if not RS.Visible then
    begin
      first := False;
      Exit;
    end;
    idx := Doc.AddText(S, font, m, fill, RS.Anchor);
    Doc.Elements[idx].Stroke := stroke;
    Doc.Elements[idx].Baseline := RS.Baseline;
    Doc.Elements[idx].Continued := cont;
    lastIdx := idx;
    first := False;
  end;

  procedure Collect(Owner: TDOMElement; const OS: TSvgStyle);
  var
    c: TDOMNode;
    xs, ys, dxs, dys, rots: TXVDoubles;
    chars: TStringArray;
    s, run: string;
    i, ci: Integer;
    px, py: TPos;
    dx, dy, rot: Double;
    cs: TSvgStyle;
    perChar: Boolean;
  begin
    xs := PosList(Owner, 'x', True);
    ys := PosList(Owner, 'y', False);
    dxs := PosList(Owner, 'dx', True);
    dys := PosList(Owner, 'dy', False);
    rots := nil;
    if HasAttr(Owner, 'rotate') then
    begin
      chars := SplitArgs(Attr(Owner, 'rotate'));
      SetLength(rots, Length(chars));
      for i := 0 to High(chars) do rots[i] := XVStrToFloat(chars[i], 0);
    end;
    ci := 0;          // characters of this owner consumed
    c := Owner.FirstChild;
    while c <> nil do
    begin
      if (c.NodeType = TEXT_NODE) or (c.NodeType = CDATA_SECTION_NODE) then
      begin
        s := CollapseSpaces(UTF8Encode(c.NodeValue), preserve);
        if not preserve then
        begin
          // collapse a space after the previous run's trailing space
          if trailingSpace and (s <> '') and (s[1] = ' ') then Delete(s, 1, 1);
          if first and (ci = 0) then s := TrimLeft(s);
        end;
        if s <> '' then
        begin
          chars := XVUtf8Chars(s);
          perChar := (Length(xs) > ci + 1) or (Length(ys) > ci + 1) or (Length(dxs) > ci + 1) or
            (Length(dys) > ci + 1) or (Length(rots) > 0);
          if perChar then
          begin
            for i := 0 to High(chars) do
            begin
              px.Has := ci < Length(xs); if px.Has then px.V := xs[ci];
              py.Has := ci < Length(ys); if py.Has then py.V := ys[ci];
              if ci < Length(dxs) then dx := dxs[ci] else dx := 0;
              if ci < Length(dys) then dy := dys[ci] else dy := 0;
              if Length(rots) > 0 then rot := rots[Min(ci, High(rots))] else rot := 0;
              Emit(chars[i], OS, px, py, dx, dy, rot);
              Inc(ci);
            end;
          end
          else
          begin
            px.Has := ci < Length(xs); if px.Has then px.V := xs[ci];
            py.Has := ci < Length(ys); if py.Has then py.V := ys[ci];
            if ci < Length(dxs) then dx := dxs[ci] else dx := 0;
            if ci < Length(dys) then dy := dys[ci] else dy := 0;
            run := s;
            Emit(run, OS, px, py, dx, dy, 0);
            Inc(ci, Length(chars));
          end;
          trailingSpace := s[Length(s)] = ' ';
        end;
      end
      else if (c is TDOMElement) and ((ElemName(c) = 'tspan') or (ElemName(c) = 'a') or (ElemName(c) = 'textpath')) then
      begin
        cs := ComputeStyle(TDOMElement(c), OS);
        if cs.Display then Collect(TDOMElement(c), cs);
      end;
      c := c.NextSibling;
    end;
  end;

var
  n: TDOMNode;
begin
  preserve := False;
  n := E;
  while (n <> nil) and (n is TDOMElement) do
  begin
    if HasAttr(n, 'xml:space') then begin preserve := Attr(n, 'xml:space') = 'preserve'; Break; end;
    n := n.ParentNode;
  end;
  first := True;
  penSet := False;
  pendingDY := 0;
  textX := 0; textY := 0;
  lastIdx := -1;
  trailingSpace := False;
  Collect(E, St);
  // trailing blanks of the whole text are dropped
  if (lastIdx >= 0) and not preserve then
    Doc.Elements[lastIdx].Text := TrimRight(Doc.Elements[lastIdx].Text);
  if penSet then ;
  if pendingDY = 0 then ;
end;

// ------------------------------ images -------------------------------------

procedure TSvgReader.EmitImage(E: TDOMElement; const Ctx: TSvgCtx; const St: TSvgStyle);
var
  h, b64: string;
  p, ii: Integer;
  img: TXVImage;
  x, y, w, hh, sx, sy, s, ox, oy: Double;
  par, align: string;
  slice: Boolean;
  m: TXVMatrix;
  clipP: TXVPath;
  ci: Integer;
begin
  h := Href(E);
  if LowerCase(Copy(h, 1, 5)) <> 'data:' then Exit;
  p := Pos(',', h);
  if p = 0 then Exit;
  if Pos(';base64', LowerCase(Copy(h, 1, p))) = 0 then Exit;
  b64 := Copy(h, p + 1, MaxInt);
  if not XVDecodeImage(XVBase64Decode(b64), img) then Exit;
  x := LenX(E, 'x', Ctx, St); y := LenY(E, 'y', Ctx, St);
  w := LenX(E, 'width', Ctx, St, img.W); hh := LenY(E, 'height', Ctx, St, img.H);
  if (w <= 0) or (hh <= 0) then Exit;
  sx := w / img.W; sy := hh / img.H;
  ox := x; oy := y;
  par := LowerCase(Trim(Attr(E, 'preserveAspectRatio')));
  slice := Pos('slice', par) > 0;
  if Pos('none', par) = 0 then
  begin
    if slice then s := Max(sx, sy) else s := Min(sx, sy);
    align := par;
    if Pos('xmin', align) > 0 then ox := x
    else if Pos('xmax', align) > 0 then ox := x + w - img.W * s
    else ox := x + (w - img.W * s) / 2;
    if Pos('ymin', align) > 0 then oy := y
    else if Pos('ymax', align) > 0 then oy := y + hh - img.H * s
    else oy := y + (hh - img.H * s) / 2;
    sx := s; sy := s;
  end;
  ii := Doc.AddImageData(img);
  m := XVMul(Ctx.CTM, TXVMatrix.Make(sx, 0, 0, sy, ox, oy));
  if slice then
  begin
    clipP := Default(TXVPath);
    clipP.Clear;
    clipP.AddRect(x, y, w, hh);
    clipP.Transform(Ctx.CTM);
    ci := Doc.AddClip(clipP, frNonZero);
    Doc.BeginGroup(ci, 1);
    Doc.AddImage(ii, m, 1);
    Doc.EndGroup;
  end
  else Doc.AddImage(ii, m, 1);
end;

// ------------------------------ structure ----------------------------------

function TSvgReader.ViewBoxMatrix(const VB: string; const AspectRatio: string; X, Y, W, H: Double; out Ok: Boolean): TXVMatrix;
var
  a: TStringArray;
  vx, vy, vw, vh, sx, sy, s, tx, ty: Double;
  par: string;
begin
  Result := TXVMatrix.Translate(X, Y);
  a := SplitArgs(VB);
  Ok := Length(a) >= 4;
  if not Ok then Exit;
  vx := XVStrToFloat(a[0]); vy := XVStrToFloat(a[1]); vw := XVStrToFloat(a[2]); vh := XVStrToFloat(a[3]);
  if (vw <= 0) or (vh <= 0) then begin Ok := False; Exit; end;
  sx := W / vw; sy := H / vh;
  par := LowerCase(Trim(AspectRatio));
  if Pos('none', par) = 1 then
    Result := TXVMatrix.Make(sx, 0, 0, sy, X - vx * sx, Y - vy * sy)
  else
  begin
    if Pos('slice', par) > 0 then s := Max(sx, sy) else s := Min(sx, sy);
    if Pos('xmin', par) > 0 then tx := X
    else if Pos('xmax', par) > 0 then tx := X + W - vw * s
    else tx := X + (W - vw * s) / 2;
    if Pos('ymin', par) > 0 then ty := Y
    else if Pos('ymax', par) > 0 then ty := Y + H - vh * s
    else ty := Y + (H - vh * s) / 2;
    Result := TXVMatrix.Make(s, 0, 0, s, tx - vx * s, ty - vy * s);
  end;
end;

procedure TSvgReader.Children(E: TDOMElement; const Ctx: TSvgCtx; const St: TSvgStyle);
var c: TDOMNode;
begin
  c := E.FirstChild;
  while c <> nil do
  begin
    if c is TDOMElement then Node(TDOMElement(c), Ctx, St);
    c := c.NextSibling;
  end;
end;

procedure TSvgReader.Node(E: TDOMElement; const Ctx: TSvgCtx; const Parent: TSvgStyle);
var
  n: string;
  St: TSvgStyle;
  C2: TSvgCtx;
  grp: Boolean;
  clip: Integer;
  box: TXVRect;
  P: TXVPath;
  ref: TDOMElement;
  x, y, w, h: Double;
  ok: Boolean;
  rectP: TXVPath;
  ci: Integer;
  child: TDOMNode;
begin
  if Depth > 64 then Exit;
  n := ElemName(E);
  if (n = 'defs') or (n = 'clippath') or (n = 'mask') or (n = 'lineargradient') or (n = 'radialgradient') or
     (n = 'pattern') or (n = 'symbol') or (n = 'marker') or (n = 'style') or (n = 'title') or (n = 'desc') or
     (n = 'metadata') or (n = 'script') or (n = 'filter') or (n = 'foreignobject') or (n = 'font') or
     (n = 'font-face') or (n = 'cursor') or (n = 'namedview') then Exit;
  St := ComputeStyle(E, Parent);
  if not St.Display then Exit;
  C2 := Ctx;
  C2.CTM := XVMul(Ctx.CTM, ParseTransformList(Attr(E, 'transform')));
  Inc(Depth);
  try
    // a group bracket for clip-path and group opacity
    clip := -1;
    if (St.ClipPath <> '') and (LowerCase(St.ClipPath) <> 'none') then
    begin
      box := XVRect(0, 0, Ctx.VW, Ctx.VH);
      if ShapePath(E, C2, St, P) then P.Bounds(box);
      clip := BuildClip(St.ClipPath, C2, box);
    end;
    grp := (clip >= 0) or ((St.Opacity < 0.999) and ((n = 'g') or (n = 'svg') or (n = 'use') or (n = 'a') or
      (n = 'switch') or (n = 'text')));
    if grp then Doc.BeginGroup(clip, St.Opacity)
    else if St.Opacity < 0.999 then
    begin
      // a single shape: opacity applies to fill and stroke together
      Doc.BeginGroup(-1, St.Opacity);
      grp := True;
    end;
    try
      if (n = 'g') or (n = 'a') then Children(E, C2, St)
      else if n = 'switch' then
      begin
        child := E.FirstChild;
        while child <> nil do
        begin
          if (child is TDOMElement) and not HasAttr(child, 'requiredExtensions') then
          begin
            Node(TDOMElement(child), C2, St);
            Break;
          end;
          child := child.NextSibling;
        end;
      end
      else if n = 'svg' then
      begin
        // a nested viewport
        x := LenX(E, 'x', Ctx, St); y := LenY(E, 'y', Ctx, St);
        w := LenX(E, 'width', Ctx, St, Ctx.VW); h := LenY(E, 'height', Ctx, St, Ctx.VH);
        if HasAttr(E, 'width') and (Pos('%', Attr(E, 'width')) > 0) then w := Ctx.VW * XVStrToFloat(StringReplace(Attr(E, 'width'), '%', '', [])) / 100;
        if HasAttr(E, 'height') and (Pos('%', Attr(E, 'height')) > 0) then h := Ctx.VH * XVStrToFloat(StringReplace(Attr(E, 'height'), '%', '', [])) / 100;
        C2.CTM := XVMul(C2.CTM, ViewBoxMatrix(Attr(E, 'viewBox'), Attr(E, 'preserveAspectRatio'), x, y, w, h, ok));
        if ok then
        begin
          C2.VW := XVStrToFloat(SplitArgs(Attr(E, 'viewBox'))[2]);
          C2.VH := XVStrToFloat(SplitArgs(Attr(E, 'viewBox'))[3]);
        end
        else begin C2.VW := w; C2.VH := h; end;
        if LowerCase(St.ClipPath) = '' then
        begin
          rectP := Default(TXVPath);
          rectP.Clear;
          rectP.AddRect(x, y, w, h);
          rectP.Transform(XVMul(Ctx.CTM, ParseTransformList(Attr(E, 'transform'))));
          ci := Doc.AddClip(rectP);
          Doc.BeginGroup(ci, 1);
          Children(E, C2, St);
          Doc.EndGroup;
        end
        else Children(E, C2, St);
      end
      else if n = 'use' then
      begin
        ref := FindId(Href(E));
        if (ref <> nil) and (ref <> E) then
        begin
          x := LenX(E, 'x', Ctx, St); y := LenY(E, 'y', Ctx, St);
          C2.CTM := XVMul(C2.CTM, TXVMatrix.Translate(x, y));
          if (ElemName(ref) = 'symbol') or (ElemName(ref) = 'svg') then
          begin
            w := LenX(E, 'width', Ctx, St, 0); h := LenY(E, 'height', Ctx, St, 0);
            if w <= 0 then w := Len(Attr(ref, 'width'), Ctx.VW, St.FontSize, Ctx.VW);
            if h <= 0 then h := Len(Attr(ref, 'height'), Ctx.VH, St.FontSize, Ctx.VH);
            C2.CTM := XVMul(C2.CTM, ViewBoxMatrix(Attr(ref, 'viewBox'), Attr(ref, 'preserveAspectRatio'), 0, 0, w, h, ok));
            if ok then
            begin
              C2.VW := XVStrToFloat(SplitArgs(Attr(ref, 'viewBox'))[2]);
              C2.VH := XVStrToFloat(SplitArgs(Attr(ref, 'viewBox'))[3]);
            end;
            Children(ref, C2, ComputeStyle(ref, St));
          end
          else Node(ref, C2, St);
        end;
      end
      else if (n = 'path') or (n = 'rect') or (n = 'circle') or (n = 'ellipse') or (n = 'line') or
              (n = 'polyline') or (n = 'polygon') then EmitShape(E, C2, St)
      else if n = 'text' then EmitText(E, C2, St)
      else if n = 'image' then begin if St.Visible then EmitImage(E, C2, St); end;
    finally
      if grp then Doc.EndGroup;
    end;
  finally
    Dec(Depth);
  end;
end;

procedure TSvgReader.Run(const Data: TBytes);
var
  ss: TStringStream;
  parser: TDOMParser;
  src: TXMLInputSource;
  root: TDOMElement;
  St: TSvgStyle;
  Ctx: TSvgCtx;
  w, h, vx, vy, vw, vh: Double;
  vb: TStringArray;
  ok: Boolean;
  s: string;
  c: TDOMNode;
begin
  SetLength(s, Length(Data));
  if Length(Data) > 0 then Move(Data[0], s[1], Length(Data));
  // UTF-8 byte order mark
  if Copy(s, 1, 3) = #$EF#$BB#$BF then Delete(s, 1, 3);
  ss := TStringStream.Create(s);
  try
    parser := TDOMParser.Create;
    src := TXMLInputSource.Create(ss);
    try
      parser.Options.PreserveWhitespace := True;
      parser.Options.Validate := False;
      parser.Options.ExpandEntities := True;
      parser.Parse(src, XDoc);
    finally
      src.Free;
      parser.Free;
    end;
  finally
    ss.Free;
  end;
  if XDoc = nil then raise EXVError.Create('SVG: cannot parse the document');
  root := XDoc.DocumentElement;
  if (root = nil) or (ElemName(root) <> 'svg') then raise EXVError.Create('SVG: no <svg> root element');
  CollectIds(root);
  CollectCss(root);
  St := ComputeStyle(root, DefaultStyle);
  vb := SplitArgs(Attr(root, 'viewBox'));
  ok := Length(vb) >= 4;
  if ok then
  begin
    vx := XVStrToFloat(vb[0]); vy := XVStrToFloat(vb[1]); vw := XVStrToFloat(vb[2]); vh := XVStrToFloat(vb[3]);
    ok := (vw > 0) and (vh > 0);
  end;
  w := Len(Attr(root, 'width'), 0, 16, 0);
  h := Len(Attr(root, 'height'), 0, 16, 0);
  if Pos('%', Attr(root, 'width')) > 0 then w := 0;
  if Pos('%', Attr(root, 'height')) > 0 then h := 0;
  if ok then
  begin
    if (w <= 0) and (h <= 0) then begin w := vw; h := vh; end
    else if w <= 0 then w := h * vw / vh
    else if h <= 0 then h := w * vh / vw;
  end
  else
  begin
    if w <= 0 then w := 300;
    if h <= 0 then h := 150;
    vx := 0; vy := 0; vw := w; vh := h;
  end;
  Doc.SetPageSize(w, h);
  Ctx.CTM := ViewBoxMatrix(XVFmt(vx, 9) + ' ' + XVFmt(vy, 9) + ' ' + XVFmt(vw, 9) + ' ' + XVFmt(vh, 9),
    Attr(root, 'preserveAspectRatio'), 0, 0, w, h, ok);
  if not ok then Ctx.CTM := TXVMatrix.Identity;
  Ctx.VW := vw; Ctx.VH := vh;
  Ctx.CTM := XVMul(Ctx.CTM, ParseTransformList(Attr(root, 'transform')));
  c := root.FirstChild;
  while c <> nil do
  begin
    if (c is TDOMElement) and (ElemName(c) = 'title') and (c.FirstChild <> nil) then
      Doc.Title := Trim(UTF8Encode(c.TextContent));
    c := c.NextSibling;
  end;
  if (St.Opacity < 0.999) or ((St.ClipPath <> '') and (LowerCase(St.ClipPath) <> 'none')) then
  begin
    Doc.BeginGroup(-1, St.Opacity);
    Children(root, Ctx, St);
    Doc.EndGroup;
  end
  else Children(root, Ctx, St);
end;

function DetectFmt(const Data: TBytes): Boolean;
begin
  Result := XVIsSVG(Data);
end;

procedure XVReadSVGDoc(Doc: TXVDocument; const Data: TBytes);
var R: TSvgReader;
begin
  R := TSvgReader.Create(Doc);
  try
    R.Run(Data);
  finally
    R.Free;
  end;
end;

initialization
  XVRegisterReader('SVG', 'svg;svgz', DetectFmt, XVReadSVGDoc);
end.
