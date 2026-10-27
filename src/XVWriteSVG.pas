unit XVWriteSVG;

{$mode delphi}{$H+}
{$R-}{$Q-}

// XelVectors - SVG writer: the document model as SVG 1.1 (gradients,
// image patterns, clip paths, group opacity, texts with tspans for continued
// runs, embedded PNG images).

interface

uses
  SysUtils, Classes, Math, XVModel, XVImageCodec;

procedure XVWriteSVGDoc(Doc: TXVDocument; Stream: TStream);
function XVDocumentToSVG(Doc: TXVDocument): string;

// path data ("M.. L.. C.. Z") of a model path
function XVPathToSvgData(const P: TXVPath): string;

implementation

function N(V: Double): string; inline;
begin
  Result := XVFmt(V, 3);
end;

function Esc(const S: string): string;
var i: Integer; c: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    case c of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
      #0..#8, #11, #12, #14..#31: ;
    else
      Result := Result + c;
    end;
  end;
end;

function MatrixStr(const M: TXVMatrix): string;
begin
  Result := 'matrix(' + XVFmt(M.A, 6) + ' ' + XVFmt(M.B, 6) + ' ' + XVFmt(M.C, 6) + ' ' + XVFmt(M.D, 6) + ' ' +
    N(M.E) + ' ' + N(M.F) + ')';
end;

function XVPathToSvgData(const P: TXVPath): string;
var
  sb: TStringBuilder;
  i, k: Integer;
begin
  sb := TStringBuilder.Create;
  try
    k := 0;
    for i := 0 to P.NCmd - 1 do
      case P.Cmds[i] of
        pcMoveTo:
          begin
            sb.Append('M').Append(N(P.Pts[k].X)).Append(' ').Append(N(P.Pts[k].Y));
            Inc(k);
          end;
        pcLineTo:
          begin
            sb.Append('L').Append(N(P.Pts[k].X)).Append(' ').Append(N(P.Pts[k].Y));
            Inc(k);
          end;
        pcCubicTo:
          begin
            sb.Append('C').Append(N(P.Pts[k].X)).Append(' ').Append(N(P.Pts[k].Y)).Append(' ')
              .Append(N(P.Pts[k + 1].X)).Append(' ').Append(N(P.Pts[k + 1].Y)).Append(' ')
              .Append(N(P.Pts[k + 2].X)).Append(' ').Append(N(P.Pts[k + 2].Y));
            Inc(k, 3);
          end;
        pcClose: sb.Append('Z');
      end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function PaintAttr(const Name: string; const P: TXVPaint; Opacity: Double): string;
var a: Double;
begin
  case P.Kind of
    pkNone: Result := ' ' + Name + '="none"';
    pkSolid:
      begin
        Result := ' ' + Name + '="' + XVHexColor(P.Color) + '"';
        a := (P.Color shr 24) / 255 * Opacity;
        if a < 0.999 then Result := Result + ' ' + Name + '-opacity="' + XVFmt(a, 3) + '"';
      end;
    pkGradient:
      begin
        Result := ' ' + Name + '="url(#g' + IntToStr(P.Index) + ')"';
        if Opacity < 0.999 then Result := Result + ' ' + Name + '-opacity="' + XVFmt(Opacity, 3) + '"';
      end;
    pkPattern:
      begin
        Result := ' ' + Name + '="url(#p' + IntToStr(P.Index) + ')"';
        if Opacity < 0.999 then Result := Result + ' ' + Name + '-opacity="' + XVFmt(Opacity, 3) + '"';
      end;
  end;
end;

function StrokeAttrs(const S: TXVStroke; Opacity: Double): string;
var i: Integer; d: string;
begin
  Result := PaintAttr('stroke', S.Paint, Opacity);
  if S.Paint.Kind = pkNone then Exit;
  if S.Width <= 0 then Result := Result + ' stroke-width="1" vector-effect="non-scaling-stroke"'
  else Result := Result + ' stroke-width="' + N(S.Width) + '"';
  case S.Cap of
    lcRound: Result := Result + ' stroke-linecap="round"';
    lcSquare: Result := Result + ' stroke-linecap="square"';
  end;
  case S.Join of
    ljRound: Result := Result + ' stroke-linejoin="round"';
    ljBevel: Result := Result + ' stroke-linejoin="bevel"';
  else
    if Abs(S.MiterLimit - 4) > 1e-6 then Result := Result + ' stroke-miterlimit="' + N(Max(1, S.MiterLimit)) + '"';
  end;
  if Length(S.Dashes) >= 2 then
  begin
    d := '';
    for i := 0 to High(S.Dashes) do
    begin
      if i > 0 then d := d + ' ';
      d := d + N(S.Dashes[i]);
    end;
    Result := Result + ' stroke-dasharray="' + d + '"';
    if S.DashOffset <> 0 then Result := Result + ' stroke-dashoffset="' + N(S.DashOffset) + '"';
  end;
end;

function FontAttrs(const F: TXVFont): string;
var d: string;
begin
  Result := ' font-family="' + Esc(F.Family) + '" font-size="' + N(F.Size) + '"';
  if F.Weight <> 400 then
  begin
    if F.Weight = 700 then Result := Result + ' font-weight="bold"'
    else Result := Result + ' font-weight="' + IntToStr(F.Weight) + '"';
  end;
  if F.Italic then Result := Result + ' font-style="italic"';
  d := '';
  if F.Underline then d := 'underline';
  if F.Strike then
  begin
    if d <> '' then d := d + ' ';
    d := d + 'line-through';
  end;
  if d <> '' then Result := Result + ' text-decoration="' + d + '"';
end;

procedure WriteDefs(Doc: TXVDocument; sb: TStringBuilder);
var
  i, k: Integer;
  g: TXVGradient;
  png: TBytes;
  img: Integer;
  sp: string;
  px: Double;
  m: TXVMatrix;
begin
  if (Length(Doc.Gradients) = 0) and (Length(Doc.Patterns) = 0) and (Length(Doc.Clips) = 0) then Exit;
  sb.Append('<defs>').Append(#10);
  for i := 0 to High(Doc.Gradients) do
  begin
    g := Doc.Gradients[i];
    case g.Spread of
      spReflect: sp := ' spreadMethod="reflect"';
      spRepeat: sp := ' spreadMethod="repeat"';
    else
      sp := '';
    end;
    if g.Kind = gkLinear then
      sb.Append('<linearGradient id="g' + IntToStr(i) + '" gradientUnits="userSpaceOnUse" x1="' + N(g.X1) +
        '" y1="' + N(g.Y1) + '" x2="' + N(g.X2) + '" y2="' + N(g.Y2) + '"')
    else
      sb.Append('<radialGradient id="g' + IntToStr(i) + '" gradientUnits="userSpaceOnUse" cx="' + N(g.CX) +
        '" cy="' + N(g.CY) + '" r="' + N(g.R) + '" fx="' + N(g.FX) + '" fy="' + N(g.FY) + '"');
    if not g.Matrix.IsIdentity then sb.Append(' gradientTransform="' + MatrixStr(g.Matrix) + '"');
    sb.Append(sp).Append('>');
    for k := 0 to High(g.Stops) do
    begin
      sb.Append('<stop offset="' + XVFmt(g.Stops[k].Offset, 4) + '" stop-color="' + XVHexColor(g.Stops[k].Color) + '"');
      if (g.Stops[k].Color shr 24) < 255 then
        sb.Append(' stop-opacity="' + XVFmt((g.Stops[k].Color shr 24) / 255, 3) + '"');
      sb.Append('/>');
    end;
    if g.Kind = gkLinear then sb.Append('</linearGradient>') else sb.Append('</radialGradient>');
    sb.Append(#10);
  end;
  for i := 0 to High(Doc.Patterns) do
  begin
    img := Doc.Patterns[i].Image;
    if (img < 0) or (img > High(Doc.Images)) then Continue;
    png := XVEncodePNG(Doc.Images[img]);
    sb.Append('<pattern id="p' + IntToStr(i) + '" patternUnits="userSpaceOnUse" width="' +
      IntToStr(Doc.Images[img].W) + '" height="' + IntToStr(Doc.Images[img].H) + '"');
    if Doc.Patterns[i].DeviceTile then
    begin
      // device pixel tiles: one tile pixel per pixel of the natural size
      if Doc.Width > 0 then px := Doc.ViewBox.Width / Doc.Width else px := 1;
      m := Doc.Patterns[i].Matrix;
      sb.Append(' patternTransform="' + MatrixStr(TXVMatrix.Make(px, 0, 0, px, m.E, m.F)) + '"');
    end
    else if not Doc.Patterns[i].Matrix.IsIdentity then
      sb.Append(' patternTransform="' + MatrixStr(Doc.Patterns[i].Matrix) + '"');
    sb.Append('><image width="' + IntToStr(Doc.Images[img].W) + '" height="' + IntToStr(Doc.Images[img].H) +
      '" xlink:href="data:image/png;base64,' + XVBase64Encode(png) + '"/></pattern>').Append(#10);
  end;
  for i := 0 to High(Doc.Clips) do
  begin
    sb.Append('<clipPath id="c' + IntToStr(i) + '"><path d="' + XVPathToSvgData(Doc.Clips[i].Path) + '"');
    if Doc.Clips[i].Rule = frEvenOdd then sb.Append(' clip-rule="evenodd"');
    sb.Append('/></clipPath>').Append(#10);
  end;
  sb.Append('</defs>').Append(#10);
end;

function TextRunAttrs(const E: TXVElement): string;
begin
  Result := FontAttrs(E.Font);
  case E.Anchor of
    taMiddle: Result := Result + ' text-anchor="middle"';
    taEnd: Result := Result + ' text-anchor="end"';
  end;
  case E.Baseline of
    tbTop: Result := Result + ' dominant-baseline="text-before-edge"';
    tbMiddle: Result := Result + ' dominant-baseline="central"';
    tbBottom: Result := Result + ' dominant-baseline="text-after-edge"';
  end;
  Result := Result + PaintAttr('fill', E.Fill, E.Opacity);
  if E.Stroke.Paint.Kind <> pkNone then Result := Result + StrokeAttrs(E.Stroke, E.Opacity);
end;

function CharXAttr(const E: TXVElement): string;
var i: Integer;
begin
  Result := '';
  if Length(E.CharX) = 0 then Exit;
  Result := ' x="';
  for i := 0 to High(E.CharX) do
  begin
    if i > 0 then Result := Result + ' ';
    Result := Result + N(E.CharX[i]);
  end;
  Result := Result + '"';
end;

function XVDocumentToSVG(Doc: TXVDocument): string;
var
  sb: TStringBuilder;
  i, j: Integer;
  e: TXVElement;
  png: TBytes;
  vb: TXVRect;
  inv: TXVMatrix;
  d: TXVPoint;
  depth: Integer;
begin
  sb := TStringBuilder.Create;
  try
    vb := Doc.ViewBox;
    if vb.IsEmpty then vb := XVRect(0, 0, Max(Doc.Width, 1), Max(Doc.Height, 1));
    sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="no"?>').Append(#10);
    sb.Append('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1"' +
      ' width="' + N(Max(Doc.Width, 1)) + '" height="' + N(Max(Doc.Height, 1)) + '" viewBox="' + N(vb.Left) + ' ' +
      N(vb.Top) + ' ' + N(vb.Width) + ' ' + N(vb.Height) + '">').Append(#10);
    if Doc.Title <> '' then sb.Append('<title>' + Esc(Doc.Title) + '</title>').Append(#10);
    WriteDefs(Doc, sb);
    if (Doc.Background shr 24) <> 0 then
    begin
      sb.Append('<rect x="' + N(vb.Left) + '" y="' + N(vb.Top) + '" width="' + N(vb.Width) + '" height="' +
        N(vb.Height) + '"' + PaintAttr('fill', XVSolid(Doc.Background), 1) + '/>').Append(#10);
    end;
    depth := 0;
    i := 0;
    while i < Doc.Count do
    begin
      e := Doc.Elements[i];
      case e.Kind of
        ekGroup:
          begin
            sb.Append('<g');
            if e.Clip >= 0 then sb.Append(' clip-path="url(#c' + IntToStr(e.Clip) + ')"');
            if e.Opacity < 0.999 then sb.Append(' opacity="' + XVFmt(e.Opacity, 3) + '"');
            sb.Append('>').Append(#10);
            Inc(depth);
          end;
        ekGroupEnd:
          if depth > 0 then
          begin
            sb.Append('</g>').Append(#10);
            Dec(depth);
          end;
        ekPath:
          begin
            sb.Append('<path d="' + XVPathToSvgData(e.Path) + '"');
            sb.Append(PaintAttr('fill', e.Fill, 1));
            if (e.Fill.Kind <> pkNone) and (e.FillRule = frEvenOdd) then sb.Append(' fill-rule="evenodd"');
            sb.Append(StrokeAttrs(e.Stroke, 1));
            if e.Opacity < 0.999 then sb.Append(' opacity="' + XVFmt(e.Opacity, 3) + '"');
            sb.Append('/>').Append(#10);
          end;
        ekText:
          begin
            sb.Append('<text transform="' + MatrixStr(e.Matrix) + '"' + TextRunAttrs(e) + CharXAttr(e) +
              ' xml:space="preserve">' + Esc(e.Text));
            // continued runs of the chunk as tspans
            inv := e.Matrix;
            inv.E := 0; inv.F := 0;
            inv := inv.Invert;
            j := i + 1;
            while (j < Doc.Count) and (Doc.Elements[j].Kind = ekText) and Doc.Elements[j].Continued do
            begin
              d := inv.Apply(Doc.Elements[j].Matrix.E, Doc.Elements[j].Matrix.F);
              sb.Append('<tspan');
              if Abs(d.X) > 1e-6 then sb.Append(' dx="' + N(d.X) + '"');
              if Abs(d.Y) > 1e-6 then sb.Append(' dy="' + N(d.Y) + '"');
              sb.Append(TextRunAttrs(Doc.Elements[j]) + '>' + Esc(Doc.Elements[j].Text) + '</tspan>');
              Inc(j);
            end;
            sb.Append('</text>').Append(#10);
            i := j - 1;
          end;
        ekImage:
          if (e.Image >= 0) and (e.Image <= High(Doc.Images)) then
          begin
            png := XVEncodePNG(Doc.Images[e.Image]);
            sb.Append('<image width="' + IntToStr(Doc.Images[e.Image].W) + '" height="' +
              IntToStr(Doc.Images[e.Image].H) + '" preserveAspectRatio="none"');
            if not e.Matrix.IsIdentity then sb.Append(' transform="' + MatrixStr(e.Matrix) + '"');
            if e.Opacity < 0.999 then sb.Append(' opacity="' + XVFmt(e.Opacity, 3) + '"');
            sb.Append(' xlink:href="data:image/png;base64,' + XVBase64Encode(png) + '"/>').Append(#10);
          end;
      end;
      Inc(i);
    end;
    while depth > 0 do
    begin
      sb.Append('</g>').Append(#10);
      Dec(depth);
    end;
    sb.Append('</svg>').Append(#10);
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

procedure XVWriteSVGDoc(Doc: TXVDocument; Stream: TStream);
var s: string;
begin
  s := XVDocumentToSVG(Doc);
  if s <> '' then Stream.WriteBuffer(s[1], Length(s));
end;

initialization
  XVRegisterWriter('SVG', 'svg', XVWriteSVGDoc);
end.
