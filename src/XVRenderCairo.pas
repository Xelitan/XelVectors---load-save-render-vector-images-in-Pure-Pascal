unit XVRenderCairo;

{$mode delphi}{$H+}
{$R-}{$Q-}

// XelVectors - Cairo renderer (Linux, BSD, macOS; on Windows when the unit is
// compiled with XV_CAIRO and libcairo-2.dll is present).
//
// Draws a document into a 32-bit raster through Cairo: paths with even-odd /
// winding fill, solid, linear and radial gradients (pad / repeat / reflect),
// image patterns, strokes with caps, joins, miters and dashes, clip groups,
// translucent groups (push_group / paint_with_alpha), texts (toy font API,
// as glyph outlines) and images.

interface

uses
  SysUtils, Math, XVModel, XVRenderCommon
  {$IF DEFINED(UNIX) or DEFINED(XV_CAIRO)}, Cairo{$ENDIF};

// Raster.W / Raster.H give the target size; the pixels are replaced.
// Returns False when Cairo is not available in this build.
function XVRenderWithCairo(Doc: TXVDocument; var Raster: TXVRaster; const Opt: TXVRenderOptions): Boolean;

implementation

{$IF DEFINED(UNIX) or DEFINED(XV_CAIRO)}

type
  { TCairoRenderer }

  TCairoRenderer = class
  private
    Doc: TXVDocument;
    W, H: Integer;
    View: TXVMatrix;
    Cr: Pcairo_t;
    MeasureSurf: Pcairo_surface_t;
    MeasureCr: Pcairo_t;
    ImgSurfs: array of Pcairo_surface_t;
    ImgData: array of array of Cardinal;
    Layout: TArray<TXVMatrix>;
    procedure SetMatrix(const M: TXVMatrix);
    procedure BuildPath(const P: TXVPath);
    function ImageSurface(Index: Integer): Pcairo_surface_t;
    function SetPaint(const Paint: TXVPaint; Alpha: Double): Boolean;
    procedure FillWith(const Paint: TXVPaint; Rule: TXVFillRule; Alpha: Double);
    procedure StrokeWith(const S: TXVStroke; Alpha: Double);
    procedure SelectFont(C: Pcairo_t; const F: TXVFont);
    function Measure(const Font: TXVFont; const S: string): Double;
    procedure DrawPathEl(const E: TXVElement);
    procedure DrawTextEl(const E: TXVElement; const M: TXVMatrix);
    procedure DrawImageEl(const E: TXVElement);
  public
    constructor Create(ADoc: TXVDocument; AW, AH: Integer; const Opt: TXVRenderOptions);
    destructor Destroy; override;
    function Run(var Raster: TXVRaster; const Opt: TXVRenderOptions): Boolean;
  end;

function CM(const M: TXVMatrix): cairo_matrix_t;
begin
  Result.xx := M.A; Result.yx := M.B; Result.xy := M.C; Result.yy := M.D; Result.x0 := M.E; Result.y0 := M.F;
end;

constructor TCairoRenderer.Create(ADoc: TXVDocument; AW, AH: Integer; const Opt: TXVRenderOptions);
begin
  inherited Create;
  Doc := ADoc;
  W := AW; H := AH;
  View := XVViewMatrix(Doc, W, H, Opt.KeepAspect);
  SetLength(ImgSurfs, Length(Doc.Images));
  SetLength(ImgData, Length(Doc.Images));
  MeasureSurf := cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
  MeasureCr := cairo_create(MeasureSurf);
end;

destructor TCairoRenderer.Destroy;
var i: Integer;
begin
  for i := 0 to High(ImgSurfs) do
    if ImgSurfs[i] <> nil then cairo_surface_destroy(ImgSurfs[i]);
  if MeasureCr <> nil then cairo_destroy(MeasureCr);
  if MeasureSurf <> nil then cairo_surface_destroy(MeasureSurf);
  inherited Destroy;
end;

procedure TCairoRenderer.SetMatrix(const M: TXVMatrix);
var m_: cairo_matrix_t;
begin
  m_ := CM(M);
  cairo_set_matrix(Cr, @m_);
end;

procedure TCairoRenderer.BuildPath(const P: TXVPath);
var i, k: Integer;
begin
  cairo_new_path(Cr);
  k := 0;
  for i := 0 to P.NCmd - 1 do
    case P.Cmds[i] of
      pcMoveTo: begin cairo_move_to(Cr, P.Pts[k].X, P.Pts[k].Y); Inc(k); end;
      pcLineTo: begin cairo_line_to(Cr, P.Pts[k].X, P.Pts[k].Y); Inc(k); end;
      pcCubicTo:
        begin
          cairo_curve_to(Cr, P.Pts[k].X, P.Pts[k].Y, P.Pts[k + 1].X, P.Pts[k + 1].Y, P.Pts[k + 2].X, P.Pts[k + 2].Y);
          Inc(k, 3);
        end;
      pcClose: cairo_close_path(Cr);
    end;
end;

// premultiplied copies of the document images
function TCairoRenderer.ImageSurface(Index: Integer): Pcairo_surface_t;
var
  i: Integer;
  c, a: Cardinal;
begin
  Result := nil;
  if (Index < 0) or (Index > High(Doc.Images)) then Exit;
  if Index > High(ImgSurfs) then
  begin
    SetLength(ImgSurfs, Length(Doc.Images));
    SetLength(ImgData, Length(Doc.Images));
  end;
  if ImgSurfs[Index] = nil then
    with Doc.Images[Index] do
      if (W > 0) and (H > 0) and (Length(Px) >= W * H) then
      begin
        SetLength(ImgData[Index], W * H);
        for i := 0 to W * H - 1 do
        begin
          c := Px[i];
          a := c shr 24;
          if a = 255 then ImgData[Index][i] := c
          else ImgData[Index][i] := (a shl 24) or ((((c shr 16) and $FF) * a div 255) shl 16) or
            ((((c shr 8) and $FF) * a div 255) shl 8) or ((c and $FF) * a div 255);
        end;
        ImgSurfs[Index] := cairo_image_surface_create_for_data(@ImgData[Index][0], CAIRO_FORMAT_ARGB32, W, H, W * 4);
      end;
  Result := ImgSurfs[Index];
end;

function TCairoRenderer.SetPaint(const Paint: TXVPaint; Alpha: Double): Boolean;
var
  g: TXVGradient;
  pat: Pcairo_pattern_t;
  i: Integer;
  m_: cairo_matrix_t;
  inv, pm: TXVMatrix;
  c: TXVColor;
  surf: Pcairo_surface_t;
  dx, dy: Double;
begin
  Result := False;
  case Paint.Kind of
    pkSolid:
      begin
        c := Paint.Color;
        cairo_set_source_rgba(Cr, XVColorR(c) / 255, XVColorG(c) / 255, XVColorB(c) / 255, XVColorAlpha(c) / 255 * Alpha);
        Result := True;
      end;
    pkGradient:
      begin
        if (Paint.Index < 0) or (Paint.Index > High(Doc.Gradients)) then Exit(SetPaint(XVSolid(Paint.Color), Alpha));
        g := Doc.Gradients[Paint.Index];
        if Length(g.Stops) = 0 then Exit;
        if Abs(g.Matrix.Det) < 1e-300 then Exit(SetPaint(XVSolid(g.Stops[High(g.Stops)].Color), Alpha));
        if g.Kind = gkLinear then pat := cairo_pattern_create_linear(g.X1, g.Y1, g.X2, g.Y2)
        else pat := cairo_pattern_create_radial(g.FX, g.FY, 0, g.CX, g.CY, g.R);
        for i := 0 to High(g.Stops) do
        begin
          c := g.Stops[i].Color;
          cairo_pattern_add_color_stop_rgba(pat, g.Stops[i].Offset, XVColorR(c) / 255, XVColorG(c) / 255,
            XVColorB(c) / 255, XVColorAlpha(c) / 255 * Alpha);
        end;
        case g.Spread of
          spReflect: cairo_pattern_set_extend(pat, CAIRO_EXTEND_REFLECT);
          spRepeat: cairo_pattern_set_extend(pat, CAIRO_EXTEND_REPEAT);
        else
          cairo_pattern_set_extend(pat, CAIRO_EXTEND_PAD);
        end;
        // pattern space <- user (document) space
        inv := g.Matrix.Invert;
        m_ := CM(inv);
        cairo_pattern_set_matrix(pat, @m_);
        cairo_set_source(Cr, pat);
        cairo_pattern_destroy(pat);
        Result := True;
      end;
    pkPattern:
      begin
        if (Paint.Index < 0) or (Paint.Index > High(Doc.Patterns)) then Exit(SetPaint(XVSolid(Paint.Color), Alpha));
        surf := ImageSurface(Doc.Patterns[Paint.Index].Image);
        if surf = nil then Exit(SetPaint(XVSolid(Paint.Color), Alpha));
        pat := cairo_pattern_create_for_surface(surf);
        cairo_pattern_set_extend(pat, CAIRO_EXTEND_REPEAT);
        pm := Doc.Patterns[Paint.Index].Matrix;
        if Doc.Patterns[Paint.Index].DeviceTile then
        begin
          // one tile pixel per output pixel, anchored at the pattern origin
          dx := Round(View.Apply(pm.E, pm.F).X); dy := Round(View.Apply(pm.E, pm.F).Y);
          inv := XVMul(TXVMatrix.Translate(-dx, -dy), View);
          cairo_pattern_set_filter(pat, CAIRO_FILTER_NEAREST);
        end
        else inv := pm.Invert;
        m_ := CM(inv);
        cairo_pattern_set_matrix(pat, @m_);
        if Alpha < 0.999 then
        begin
          // translucent pattern: through a group
          cairo_set_source(Cr, pat);
          cairo_pattern_destroy(pat);
          Result := True;
          Exit;
        end;
        cairo_set_source(Cr, pat);
        cairo_pattern_destroy(pat);
        Result := True;
      end;
  end;
end;

procedure TCairoRenderer.FillWith(const Paint: TXVPaint; Rule: TXVFillRule; Alpha: Double);
begin
  if Paint.Kind = pkNone then Exit;
  if Rule = frEvenOdd then cairo_set_fill_rule(Cr, CAIRO_FILL_RULE_EVEN_ODD)
  else cairo_set_fill_rule(Cr, CAIRO_FILL_RULE_WINDING);
  if Paint.Kind = pkPattern then
  begin
    if not SetPaint(Paint, 1) then Exit;
    if Alpha < 0.999 then
    begin
      cairo_save(Cr);
      cairo_clip_preserve(Cr);
      cairo_paint_with_alpha(Cr, Alpha);
      cairo_restore(Cr);
      Exit;
    end;
  end
  else if not SetPaint(Paint, Alpha) then Exit;
  cairo_fill_preserve(Cr);
end;

procedure TCairoRenderer.StrokeWith(const S: TXVStroke; Alpha: Double);
var
  w: Double;
  d: array of Double;
  i: Integer;
  total: Double;
begin
  if S.Paint.Kind = pkNone then Exit;
  if not SetPaint(S.Paint, Alpha) then Exit;
  w := S.Width;
  if w <= 0 then w := 1 / Max(View.ScaleFactor, 1e-12);
  cairo_set_line_width(Cr, w);
  case S.Cap of
    lcRound: cairo_set_line_cap(Cr, CAIRO_LINE_CAP_ROUND);
    lcSquare: cairo_set_line_cap(Cr, CAIRO_LINE_CAP_SQUARE);
  else
    cairo_set_line_cap(Cr, CAIRO_LINE_CAP_BUTT);
  end;
  case S.Join of
    ljRound: cairo_set_line_join(Cr, CAIRO_LINE_JOIN_ROUND);
    ljBevel: cairo_set_line_join(Cr, CAIRO_LINE_JOIN_BEVEL);
  else
    cairo_set_line_join(Cr, CAIRO_LINE_JOIN_MITER);
  end;
  cairo_set_miter_limit(Cr, Max(1, S.MiterLimit));
  if Length(S.Dashes) >= 2 then
  begin
    SetLength(d, Length(S.Dashes));
    total := 0;
    for i := 0 to High(d) do
    begin
      d[i] := Max(S.Dashes[i], 0);
      total := total + d[i];
    end;
    if total > 1e-12 then cairo_set_dash(Cr, @d[0], Length(d), S.DashOffset)
    else cairo_set_dash(Cr, nil, 0, 0);
  end
  else cairo_set_dash(Cr, nil, 0, 0);
  cairo_stroke_preserve(Cr);
end;

procedure TCairoRenderer.SelectFont(C: Pcairo_t; const F: TXVFont);
var
  slant: cairo_font_slant_t;
  weight: cairo_font_weight_t;
  fam: string;
begin
  if F.Italic then slant := CAIRO_FONT_SLANT_ITALIC else slant := CAIRO_FONT_SLANT_NORMAL;
  if F.Weight >= 600 then weight := CAIRO_FONT_WEIGHT_BOLD else weight := CAIRO_FONT_WEIGHT_NORMAL;
  fam := F.Family;
  // common Windows names map to fontconfig aliases
  if SameText(fam, 'Arial') or SameText(fam, 'Helvetica') or SameText(fam, 'Segoe UI') then fam := 'sans-serif'
  else if SameText(fam, 'Times New Roman') or SameText(fam, 'Times') then fam := 'serif'
  else if SameText(fam, 'Courier New') or SameText(fam, 'Courier') then fam := 'monospace';
  cairo_select_font_face(C, PChar(fam), slant, weight);
end;

function TCairoRenderer.Measure(const Font: TXVFont; const S: string): Double;
var ext: cairo_text_extents_t;
begin
  Result := 0;
  if S = '' then Exit;
  SelectFont(MeasureCr, Font);
  cairo_set_font_size(MeasureCr, 100);
  cairo_text_extents(MeasureCr, PChar(S), @ext);
  Result := ext.x_advance * Font.Size / 100;
end;

procedure TCairoRenderer.DrawPathEl(const E: TXVElement);
var group: Boolean;
begin
  if E.Path.NCmd = 0 then Exit;
  group := (E.Opacity < 0.999) and (E.Fill.Kind <> pkNone) and (E.Stroke.Paint.Kind <> pkNone);
  if group then cairo_push_group(Cr);
  BuildPath(E.Path);
  if group then
  begin
    FillWith(E.Fill, E.FillRule, 1);
    StrokeWith(E.Stroke, 1);
    cairo_new_path(Cr);
    cairo_pop_group_to_source(Cr);
    cairo_paint_with_alpha(Cr, E.Opacity);
  end
  else
  begin
    FillWith(E.Fill, E.FillRule, E.Opacity);
    StrokeWith(E.Stroke, E.Opacity);
    cairo_new_path(Cr);
  end;
end;

procedure TCairoRenderer.DrawTextEl(const E: TXVElement; const M: TXVMatrix);
var
  fe: cairo_font_extents_t;
  te: cairo_text_extents_t;
  y0, x, w, lw: Double;
  ch: TStringArray;
  k: Integer;
begin
  if (E.Text = '') or ((E.Fill.Kind = pkNone) and (E.Stroke.Paint.Kind = pkNone)) then Exit;
  if (E.Font.Size <= 0) or (Abs(M.Det) < 1e-300) then Exit;
  cairo_save(Cr);
  SetMatrix(XVMul(View, M));
  SelectFont(Cr, E.Font);
  cairo_set_font_size(Cr, E.Font.Size);
  cairo_font_extents(Cr, @fe);
  case E.Baseline of
    tbTop: y0 := fe.ascent;
    tbMiddle: y0 := (fe.ascent - fe.descent) / 2;
    tbBottom: y0 := -fe.descent;
  else
    y0 := 0;
  end;
  cairo_new_path(Cr);
  if Length(E.CharX) > 0 then
  begin
    ch := XVUtf8Chars(E.Text);
    for k := 0 to High(ch) do
    begin
      if k <= High(E.CharX) then x := E.CharX[k] else x := E.CharX[High(E.CharX)];
      cairo_move_to(Cr, x, y0);
      cairo_text_path(Cr, PChar(ch[k]));
    end;
  end
  else
  begin
    cairo_move_to(Cr, 0, y0);
    cairo_text_path(Cr, PChar(E.Text));
  end;
  // decorations
  if E.Font.Underline or E.Font.Strike then
  begin
    cairo_text_extents(Cr, PChar(E.Text), @te);
    w := te.x_advance;
    lw := E.Font.Size / 14;
    if E.Font.Underline then cairo_rectangle(Cr, 0, y0 + E.Font.Size * 0.1, w, lw);
    if E.Font.Strike then cairo_rectangle(Cr, 0, y0 - E.Font.Size * 0.3, w, lw);
  end;
  // paints are defined in document space
  SetMatrix(View);
  FillWith(E.Fill, frNonZero, E.Opacity);
  StrokeWith(E.Stroke, E.Opacity);
  cairo_new_path(Cr);
  cairo_restore(Cr);
end;

procedure TCairoRenderer.DrawImageEl(const E: TXVElement);
var
  surf: Pcairo_surface_t;
  pat: Pcairo_pattern_t;
begin
  surf := ImageSurface(E.Image);
  if surf = nil then Exit;
  cairo_save(Cr);
  SetMatrix(XVMul(View, E.Matrix));
  cairo_set_source_surface(Cr, surf, 0, 0);
  pat := cairo_get_source(Cr);
  cairo_pattern_set_extend(pat, CAIRO_EXTEND_PAD);
  if XVMul(View, E.Matrix).ScaleFactor > 4 then cairo_pattern_set_filter(pat, CAIRO_FILTER_NEAREST)
  else cairo_pattern_set_filter(pat, CAIRO_FILTER_GOOD);
  cairo_rectangle(Cr, 0, 0, Doc.Images[E.Image].W, Doc.Images[E.Image].H);
  cairo_clip(Cr);
  cairo_paint_with_alpha(Cr, E.Opacity);
  cairo_restore(Cr);
end;

function TCairoRenderer.Run(var Raster: TXVRaster; const Opt: TXVRenderOptions): Boolean;
var
  surf: Pcairo_surface_t;
  i: Integer;
  e: TXVElement;
  groups: array of Double;       // opacity of the open groups (< 1: a pushed layer)
  c: TXVColor;
begin
  Result := False;
  SetLength(Raster.Px, W * H);
  XVFillRaster(Raster, Opt.Background);
  XVPremultiply(Raster);
  surf := cairo_image_surface_create_for_data(@Raster.Px[0], CAIRO_FORMAT_ARGB32, W, H, W * 4);
  if surf = nil then Exit;
  Cr := cairo_create(surf);
  try
    if Opt.AntiAlias then cairo_set_antialias(Cr, CAIRO_ANTIALIAS_DEFAULT)
    else cairo_set_antialias(Cr, CAIRO_ANTIALIAS_NONE);
    SetMatrix(View);
    if Opt.UseDocBackground and ((Doc.Background shr 24) <> 0) then
    begin
      c := Doc.Background;
      cairo_set_source_rgba(Cr, XVColorR(c) / 255, XVColorG(c) / 255, XVColorB(c) / 255, XVColorAlpha(c) / 255);
      with Doc.ViewBox do cairo_rectangle(Cr, Left, Top, Right - Left, Bottom - Top);
      cairo_fill(Cr);
    end;
    Layout := XVLayoutTexts(Doc, Measure);
    groups := nil;
    for i := 0 to Doc.Count - 1 do
    begin
      e := Doc.Elements[i];
      case e.Kind of
        ekGroup:
          begin
            cairo_save(Cr);
            if (e.Clip >= 0) and (e.Clip <= High(Doc.Clips)) then
            begin
              BuildPath(Doc.Clips[e.Clip].Path);
              if Doc.Clips[e.Clip].Rule = frEvenOdd then cairo_set_fill_rule(Cr, CAIRO_FILL_RULE_EVEN_ODD)
              else cairo_set_fill_rule(Cr, CAIRO_FILL_RULE_WINDING);
              cairo_clip(Cr);
            end;
            SetLength(groups, Length(groups) + 1);
            groups[High(groups)] := e.Opacity;
            if e.Opacity < 0.999 then cairo_push_group(Cr);
          end;
        ekGroupEnd:
          if Length(groups) > 0 then
          begin
            if groups[High(groups)] < 0.999 then
            begin
              cairo_pop_group_to_source(Cr);
              cairo_paint_with_alpha(Cr, Max(0, groups[High(groups)]));
            end;
            SetLength(groups, Length(groups) - 1);
            cairo_restore(Cr);
          end;
        ekPath: DrawPathEl(e);
        ekText: DrawTextEl(e, Layout[i]);
        ekImage: DrawImageEl(e);
      end;
    end;
    while Length(groups) > 0 do
    begin
      if groups[High(groups)] < 0.999 then
      begin
        cairo_pop_group_to_source(Cr);
        cairo_paint_with_alpha(Cr, Max(0, groups[High(groups)]));
      end;
      SetLength(groups, Length(groups) - 1);
      cairo_restore(Cr);
    end;
    cairo_surface_flush(surf);
    Result := True;
  finally
    cairo_destroy(Cr);
    cairo_surface_destroy(surf);
  end;
  XVUnpremultiply(Raster);
end;

function XVRenderWithCairo(Doc: TXVDocument; var Raster: TXVRaster; const Opt: TXVRenderOptions): Boolean;
var R: TCairoRenderer;
begin
  Result := False;
  if (Raster.W <= 0) or (Raster.H <= 0) then Exit;
  R := TCairoRenderer.Create(Doc, Raster.W, Raster.H, Opt);
  try
    Result := R.Run(Raster, Opt);
  finally
    R.Free;
  end;
end;

{$ELSE}

function XVRenderWithCairo(Doc: TXVDocument; var Raster: TXVRaster; const Opt: TXVRenderOptions): Boolean;
begin
  Result := False;
end;

{$ENDIF}

end.
