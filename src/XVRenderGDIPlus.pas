unit XVRenderGDIPlus;

{$mode delphi}{$H+}
{$R-}{$Q-}

// XelVectors - GDI+ renderer (Windows).
//
// Draws a document into a 32-bit raster through GDI+: paths with even-odd /
// winding fill, solid, linear and radial gradients (pad / repeat / reflect),
// image patterns, strokes with caps, joins, miters and dashes, clip groups,
// translucent groups (rendered into a layer and blended), texts as glyph
// outlines (so they take gradients, rotation and any scale) and images.

interface

uses
  SysUtils, XVModel, XVRenderCommon
  {$IFDEF MSWINDOWS}, Windows, XVGdiPlusApi{$ENDIF}, Math;

// Raster.W / Raster.H give the target size; the pixels are replaced.
// Returns False when GDI+ is not available.
function XVRenderWithGdiPlus(Doc: TXVDocument; var Raster: TXVRaster; const Opt: TXVRenderOptions): Boolean;

implementation

{$IFDEF MSWINDOWS}

type
  TLayer = record
    G: GpGraphics;
    Bmp: GpBitmap;
    State: Cardinal;
    Opacity: Double;
    IsLayer: Boolean;
  end;

  TFontRec = record
    Key: string;
    Family: GpFontFamily;
    Owned: Boolean;
  end;

  TMeasureFont = record
    Key: string;
    Font: GpFont;
  end;

  { TGdipRenderer }

  TGdipRenderer = class
  private
    Doc: TXVDocument;
    W, H: Integer;
    View: TXVMatrix;
    ViewM: GpMatrix;
    G: GpGraphics;                    // current target
    MainBmp: GpBitmap;
    Stack: array of TLayer;
    ImgBmps: array of GpBitmap;
    Fonts: array of TFontRec;
    MFonts: array of TMeasureFont;
    MeasureBmp: GpBitmap;
    MeasureG: GpGraphics;
    Format: GpStringFormat;
    Layout: TArray<TXVMatrix>;
    AA: Boolean;
    procedure SetupGraphics(AG: GpGraphics);
    function MakeMatrix(const M: TXVMatrix): GpMatrix;
    function BuildPath(const P: TXVPath; Rule: TXVFillRule): GpPath;
    function ImageBitmap(Index: Integer): GpBitmap;
    function MakeBrush(const Paint: TXVPaint; const Bounds: TXVRect; Alpha: Double; out Pre: GpBrush): GpBrush;
    procedure FillWith(const Paint: TXVPaint; Path: GpPath; const Bounds: TXVRect; Alpha: Double);
    procedure StrokeWith(const S: TXVStroke; Path: GpPath; const Bounds: TXVRect; Alpha: Double);
    function GetFamily(const Name: string; var Style: Integer): GpFontFamily;
    function FontStyle(const F: TXVFont): Integer;
    function Measure(const Font: TXVFont; const S: string): Double;
    procedure BeginLayer(Clip: Integer; Opacity: Double; ForceLayer: Boolean);
    procedure EndLayer;
    procedure DrawPathEl(const E: TXVElement);
    procedure DrawTextEl(const E: TXVElement; const M: TXVMatrix);
    procedure DrawImageEl(const E: TXVElement);
  public
    constructor Create(ADoc: TXVDocument; AW, AH: Integer; const Opt: TXVRenderOptions);
    destructor Destroy; override;
    function Run(var Raster: TXVRaster; const Opt: TXVRenderOptions): Boolean;
  end;

function Clamp01(v: Double): Double; inline;
begin
  if v < 0 then Result := 0 else if v > 1 then Result := 1 else Result := v;
end;

function ColorA(c: TXVColor; Alpha: Double): ARGB; inline;
begin
  if Alpha >= 1 then Result := c else Result := XVMulAlpha(c, Alpha);
end;

constructor TGdipRenderer.Create(ADoc: TXVDocument; AW, AH: Integer; const Opt: TXVRenderOptions);
var fmt: GpStringFormat;
begin
  inherited Create;
  Doc := ADoc;
  W := AW; H := AH;
  AA := Opt.AntiAlias;
  View := XVViewMatrix(Doc, W, H, Opt.KeepAspect);
  ViewM := MakeMatrix(View);
  SetLength(ImgBmps, Length(Doc.Images));
  GdipCreateBitmapFromScan0(1, 1, 4, PixelFormat32bppPARGB, nil, MeasureBmp);
  GdipGetImageGraphicsContext(MeasureBmp, MeasureG);
  GdipStringFormatGetGenericTypographic(fmt);
  GdipCloneStringFormat(fmt, Format);
  GdipSetStringFormatFlags(Format, StringFormatFlagsMeasureTrailingSpaces or StringFormatFlagsNoWrap or
    StringFormatFlagsNoClip);
end;

destructor TGdipRenderer.Destroy;
var i: Integer;
begin
  for i := 0 to High(ImgBmps) do
    if ImgBmps[i] <> nil then GdipDisposeImage(ImgBmps[i]);
  for i := 0 to High(Fonts) do
    if Fonts[i].Owned and (Fonts[i].Family <> nil) then GdipDeleteFontFamily(Fonts[i].Family);
  for i := 0 to High(MFonts) do
    if MFonts[i].Font <> nil then GdipDeleteFont(MFonts[i].Font);
  if Format <> nil then GdipDeleteStringFormat(Format);
  if MeasureG <> nil then GdipDeleteGraphics(MeasureG);
  if MeasureBmp <> nil then GdipDisposeImage(MeasureBmp);
  if ViewM <> nil then GdipDeleteMatrix(ViewM);
  inherited Destroy;
end;

procedure TGdipRenderer.SetupGraphics(AG: GpGraphics);
begin
  if AA then GdipSetSmoothingMode(AG, SmoothingModeAntiAlias) else GdipSetSmoothingMode(AG, SmoothingModeNone);
  GdipSetPixelOffsetMode(AG, PixelOffsetModeHalf);
  GdipSetInterpolationMode(AG, InterpolationModeHighQualityBicubic);
  // plain (not gamma corrected) blending, as SVG and Cairo do
  GdipSetCompositingQuality(AG, CompositingQualityAssumeLinear);
  GdipSetTextRenderingHint(AG, TextRenderingHintAntiAlias);
  GdipSetWorldTransform(AG, ViewM);
end;

function TGdipRenderer.MakeMatrix(const M: TXVMatrix): GpMatrix;
begin
  Result := nil;
  GdipCreateMatrix2(M.A, M.B, M.C, M.D, M.E, M.F, Result);
end;

function TGdipRenderer.BuildPath(const P: TXVPath; Rule: TXVFillRule): GpPath;
var
  i, k: Integer;
  cx, cy: Single;
begin
  Result := nil;
  if Rule = frEvenOdd then GdipCreatePath(FillModeAlternate, Result)
  else GdipCreatePath(FillModeWinding, Result);
  k := 0;
  cx := 0; cy := 0;
  for i := 0 to P.NCmd - 1 do
    case P.Cmds[i] of
      pcMoveTo:
        begin
          GdipStartPathFigure(Result);
          cx := P.Pts[k].X; cy := P.Pts[k].Y;
          Inc(k);
        end;
      pcLineTo:
        begin
          GdipAddPathLine(Result, cx, cy, P.Pts[k].X, P.Pts[k].Y);
          cx := P.Pts[k].X; cy := P.Pts[k].Y;
          Inc(k);
        end;
      pcCubicTo:
        begin
          GdipAddPathBezier(Result, cx, cy, P.Pts[k].X, P.Pts[k].Y, P.Pts[k + 1].X, P.Pts[k + 1].Y,
            P.Pts[k + 2].X, P.Pts[k + 2].Y);
          cx := P.Pts[k + 2].X; cy := P.Pts[k + 2].Y;
          Inc(k, 3);
        end;
      pcClose: GdipClosePathFigure(Result);
    end;
end;

function TGdipRenderer.ImageBitmap(Index: Integer): GpBitmap;
begin
  Result := nil;
  if (Index < 0) or (Index > High(Doc.Images)) then Exit;
  if Index > High(ImgBmps) then SetLength(ImgBmps, Length(Doc.Images));
  if ImgBmps[Index] = nil then
    with Doc.Images[Index] do
      if (W > 0) and (H > 0) and (Length(Px) >= W * H) then
        GdipCreateBitmapFromScan0(W, H, W * 4, PixelFormat32bppARGB, @Px[0], ImgBmps[Index]);
  Result := ImgBmps[Index];
end;

// Brush for a paint over a shape with the given document-space bounds. A
// radial gradient also returns the brush of its outside colour in Pre.
function TGdipRenderer.MakeBrush(const Paint: TXVPaint; const Bounds: TXVRect; Alpha: Double; out Pre: GpBrush): GpBrush;
var
  gr: TXVGradient;
  inv, m: TXVMatrix;
  dx, dy, d2, t, tmin, tmax, a, b: Double;
  corners: array[0..3] of TXVPoint;
  i, n, k: Integer;
  cols: array of ARGB;
  poss: array of Single;
  p1, p2, cp: TGPPointF;
  gm: GpMatrix;
  path: GpPath;
  wrap: Integer;
  img: GpBitmap;
  r: Double;
  fx, fy, dist: Double;

  procedure AddStop(Pos: Double; C: TXVColor);
  begin
    SetLength(cols, n + 1);
    SetLength(poss, n + 1);
    cols[n] := ColorA(C, Alpha);
    poss[n] := Pos;
    Inc(n);
  end;

begin
  Result := nil;
  Pre := nil;
  case Paint.Kind of
    pkSolid: GdipCreateSolidFill(ColorA(Paint.Color, Alpha), Result);
    pkGradient:
      begin
        if (Paint.Index < 0) or (Paint.Index > High(Doc.Gradients)) then
        begin
          GdipCreateSolidFill(ColorA(Paint.Color, Alpha), Result);
          Exit;
        end;
        gr := Doc.Gradients[Paint.Index];
        if Length(gr.Stops) = 0 then Exit;
        if Length(gr.Stops) = 1 then
        begin
          GdipCreateSolidFill(ColorA(gr.Stops[0].Color, Alpha), Result);
          Exit;
        end;
        n := 0;
        if gr.Kind = gkLinear then
        begin
          dx := gr.X2 - gr.X1; dy := gr.Y2 - gr.Y1;
          d2 := dx * dx + dy * dy;
          if (d2 < 1e-24) or (Abs(gr.Matrix.Det) < 1e-300) then
          begin
            GdipCreateSolidFill(ColorA(gr.Stops[High(gr.Stops)].Color, Alpha), Result);
            Exit;
          end;
          a := 0; b := 1;
          wrap := WrapModeTile;
          if gr.Spread = spPad then
          begin
            // GDI+ line brushes always repeat: stretch the gradient over the
            // whole shape and pad it with the end colours
            inv := gr.Matrix.Invert;
            corners[0] := inv.Apply(Bounds.Left, Bounds.Top);
            corners[1] := inv.Apply(Bounds.Right, Bounds.Top);
            corners[2] := inv.Apply(Bounds.Left, Bounds.Bottom);
            corners[3] := inv.Apply(Bounds.Right, Bounds.Bottom);
            tmin := 1e300; tmax := -1e300;
            for i := 0 to 3 do
            begin
              t := ((corners[i].X - gr.X1) * dx + (corners[i].Y - gr.Y1) * dy) / d2;
              tmin := Min(tmin, t); tmax := Max(tmax, t);
            end;
            a := Min(0, tmin - 0.01); b := Max(1, tmax + 0.01);
          end
          else if gr.Spread = spReflect then wrap := WrapModeTileFlipX;
          if gr.Stops[0].Offset > 0 then AddStop(0, gr.Stops[0].Color);
          for i := 0 to High(gr.Stops) do AddStop(gr.Stops[i].Offset, gr.Stops[i].Color);
          if gr.Stops[High(gr.Stops)].Offset < 1 then AddStop(1, gr.Stops[High(gr.Stops)].Color);
          // remap to the stretched range
          for i := 0 to n - 1 do poss[i] := (poss[i] - a) / (b - a);
          if a < 0 then
          begin
            Insert(cols[0], cols, 0); Insert(Single(0), poss, 0); Inc(n);
          end;
          if b > 1 then
          begin
            SetLength(cols, n + 1); SetLength(poss, n + 1);
            cols[n] := cols[n - 1]; poss[n] := 1; Inc(n);
          end;
          poss[0] := 0; poss[n - 1] := 1;
          for i := 1 to n - 1 do if poss[i] < poss[i - 1] then poss[i] := poss[i - 1];
          p1.X := gr.X1 + a * dx; p1.Y := gr.Y1 + a * dy;
          p2.X := gr.X1 + b * dx; p2.Y := gr.Y1 + b * dy;
          GdipCreateLineBrush(p1, p2, cols[0], cols[n - 1], wrap, Result);
          if Result = nil then Exit;
          GdipSetLinePresetBlend(Result, @cols[0], @poss[0], n);
          GdipSetLineGammaCorrection(Result, False);
          gm := MakeMatrix(gr.Matrix);
          // the brush keeps its own rotation: the gradient matrix comes after it
          GdipMultiplyLineTransform(Result, gm, MatrixOrderAppend);
          GdipDeleteMatrix(gm);
        end
        else
        begin
          r := gr.R;
          if (r <= 1e-12) or (Abs(gr.Matrix.Det) < 1e-300) then
          begin
            GdipCreateSolidFill(ColorA(gr.Stops[High(gr.Stops)].Color, Alpha), Result);
            Exit;
          end;
          path := nil;
          GdipCreatePath(FillModeWinding, path);
          GdipAddPathEllipse(path, gr.CX - r, gr.CY - r, 2 * r, 2 * r);
          gm := MakeMatrix(gr.Matrix);
          GdipTransformPath(path, gm);
          GdipDeleteMatrix(gm);
          GdipCreatePathGradientFromPath(path, Result);
          GdipDeletePath(path);
          if Result = nil then Exit;
          // focus inside the circle
          fx := gr.FX; fy := gr.FY;
          dist := Hypot(fx - gr.CX, fy - gr.CY);
          if dist > r * 0.99 then
          begin
            fx := gr.CX + (fx - gr.CX) * r * 0.99 / dist;
            fy := gr.CY + (fy - gr.CY) * r * 0.99 / dist;
          end;
          m := gr.Matrix;
          cp.X := m.Apply(fx, fy).X; cp.Y := m.Apply(fx, fy).Y;
          GdipSetPathGradientCenterPoint(Result, cp);
          // GDI+ blends from the boundary (0) to the centre (1)
          k := High(gr.Stops);
          if gr.Stops[k].Offset < 1 then AddStop(0, gr.Stops[k].Color);
          for i := k downto 0 do AddStop(1 - gr.Stops[i].Offset, gr.Stops[i].Color);
          if gr.Stops[0].Offset > 0 then AddStop(1, gr.Stops[0].Color);
          poss[0] := 0; poss[n - 1] := 1;
          for i := 1 to n - 1 do if poss[i] < poss[i - 1] then poss[i] := poss[i - 1];
          GdipSetPathGradientPresetBlend(Result, @cols[0], @poss[0], n);
          GdipCreateSolidFill(ColorA(gr.Stops[k].Color, Alpha), Pre);
        end;
      end;
    pkPattern:
      begin
        if (Paint.Index < 0) or (Paint.Index > High(Doc.Patterns)) then
        begin
          GdipCreateSolidFill(ColorA(Paint.Color, Alpha), Result);
          Exit;
        end;
        img := ImageBitmap(Doc.Patterns[Paint.Index].Image);
        if img = nil then
        begin
          GdipCreateSolidFill(ColorA(Paint.Color, Alpha), Result);
          Exit;
        end;
        GdipCreateTexture(img, WrapModeTile, Result);
        if Result = nil then Exit;
        if Doc.Patterns[Paint.Index].DeviceTile then
        begin
          // one tile pixel per output pixel, anchored at the pattern origin
          m := Doc.Patterns[Paint.Index].Matrix;
          cp.X := Round(View.Apply(m.E, m.F).X); cp.Y := Round(View.Apply(m.E, m.F).Y);
          gm := MakeMatrix(XVMul(View.Invert, TXVMatrix.Translate(cp.X, cp.Y)));
        end
        else
          gm := MakeMatrix(Doc.Patterns[Paint.Index].Matrix);
        GdipSetTextureTransform(Result, gm);
        GdipDeleteMatrix(gm);
      end;
  end;
end;

procedure TGdipRenderer.FillWith(const Paint: TXVPaint; Path: GpPath; const Bounds: TXVRect; Alpha: Double);
var br, pre: GpBrush;
begin
  if Paint.Kind = pkNone then Exit;
  br := MakeBrush(Paint, Bounds, Alpha, pre);
  if pre <> nil then
  begin
    GdipFillPath(G, pre, Path);
    GdipDeleteBrush(pre);
  end;
  if br <> nil then
  begin
    GdipFillPath(G, br, Path);
    GdipDeleteBrush(br);
  end;
end;

procedure TGdipRenderer.StrokeWith(const S: TXVStroke; Path: GpPath; const Bounds: TXVRect; Alpha: Double);
var
  br, pre: GpBrush;
  pen: GpPen;
  w: Double;
  dash: array of Single;
  i: Integer;
  cap, join: Integer;
  total: Double;

  procedure Setup(P: GpPen);
  begin
    GdipSetPenLineCap197819(P, cap, cap, Ord(S.Cap = lcRound) * DashCapRound);
    GdipSetPenLineJoin(P, join);
    GdipSetPenMiterLimit(P, Max(1, S.MiterLimit));
    if Length(dash) > 0 then
    begin
      GdipSetPenDashArray(P, @dash[0], Length(dash));
      GdipSetPenDashOffset(P, S.DashOffset / w);
    end;
  end;

begin
  if S.Paint.Kind = pkNone then Exit;
  w := S.Width;
  if w <= 0 then
    w := 1 / Max(View.ScaleFactor, 1e-12);       // one device pixel
  case S.Cap of
    lcRound: cap := LineCapRound;
    lcSquare: cap := LineCapSquare;
  else
    cap := LineCapFlat;
  end;
  case S.Join of
    ljRound: join := LineJoinRound;
    ljBevel: join := LineJoinBevel;
  else
    join := LineJoinMiterClipped;
  end;
  dash := nil;
  if Length(S.Dashes) >= 2 then
  begin
    total := 0;
    SetLength(dash, Length(S.Dashes));
    for i := 0 to High(S.Dashes) do
    begin
      // GDI+ dash lengths are in pen widths and must not be zero
      dash[i] := Max(S.Dashes[i] / w, 0.01);
      total := total + S.Dashes[i];
    end;
    if total <= 1e-12 then dash := nil;
  end;
  br := MakeBrush(S.Paint, Bounds, Alpha, pre);
  if pre <> nil then
  begin
    pen := nil;
    GdipCreatePen2(pre, w, UnitWorld, pen);
    if pen <> nil then
    begin
      Setup(pen);
      GdipDrawPath(G, pen, Path);
      GdipDeletePen(pen);
    end;
    GdipDeleteBrush(pre);
  end;
  if br <> nil then
  begin
    pen := nil;
    GdipCreatePen2(br, w, UnitWorld, pen);
    if pen <> nil then
    begin
      Setup(pen);
      GdipDrawPath(G, pen, Path);
      GdipDeletePen(pen);
    end;
    GdipDeleteBrush(br);
  end;
end;

procedure TGdipRenderer.BeginLayer(Clip: Integer; Opacity: Double; ForceLayer: Boolean);
var
  L: TLayer;
  cp: GpPath;
  n: Integer;
begin
  L := Default(TLayer);
  L.Opacity := Opacity;
  GdipSaveGraphics(G, L.State);
  L.G := G;
  L.IsLayer := ForceLayer or (Opacity < 0.999);
  n := Length(Stack);
  SetLength(Stack, n + 1);
  if L.IsLayer then
  begin
    GdipCreateBitmapFromScan0(W, H, 0, PixelFormat32bppPARGB, nil, L.Bmp);
    if L.Bmp <> nil then
    begin
      GdipGetImageGraphicsContext(L.Bmp, G);
      GdipGraphicsClear(G, 0);
      SetupGraphics(G);
    end
    else L.IsLayer := False;
  end;
  Stack[n] := L;
  if (Clip >= 0) and (Clip <= High(Doc.Clips)) then
  begin
    cp := BuildPath(Doc.Clips[Clip].Path, Doc.Clips[Clip].Rule);
    GdipSetClipPath(G, cp, CombineModeIntersect);
    GdipDeletePath(cp);
  end;
end;

procedure TGdipRenderer.EndLayer;
var
  L: TLayer;
  attr: GpImageAttributes;
  cm: TColorMatrix;
  i: Integer;
begin
  if Length(Stack) = 0 then Exit;
  L := Stack[High(Stack)];
  SetLength(Stack, Length(Stack) - 1);
  if L.IsLayer then
  begin
    GdipDeleteGraphics(G);
    G := L.G;
    GdipResetWorldTransform(G);
    attr := nil;
    GdipCreateImageAttributes(attr);
    FillChar(cm, SizeOf(cm), 0);
    for i := 0 to 4 do cm[i, i] := 1;
    cm[3, 3] := Clamp01(L.Opacity);
    GdipSetImageAttributesColorMatrix(attr, ColorAdjustTypeDefault, True, @cm, nil, ColorMatrixFlagsDefault);
    GdipSetPixelOffsetMode(G, PixelOffsetModeNone);
    GdipDrawImageRectRect(G, L.Bmp, 0, 0, W, H, 0, 0, W, H, UnitPixel, attr, nil, nil);
    GdipSetPixelOffsetMode(G, PixelOffsetModeHalf);
    GdipDisposeImageAttributes(attr);
    GdipDisposeImage(L.Bmp);
    GdipSetWorldTransform(G, ViewM);
  end;
  GdipRestoreGraphics(G, L.State);
end;

procedure TGdipRenderer.DrawPathEl(const E: TXVElement);
var
  path: GpPath;
  b: TXVRect;
  alpha: Double;
  layer: Boolean;
begin
  if E.Path.NCmd = 0 then Exit;
  if not E.Path.Bounds(b) then Exit;
  alpha := E.Opacity;
  // translucent patterns, or fill and stroke that would overlap: one layer
  layer := (alpha < 0.999) and ((E.Fill.Kind = pkPattern) or (E.Stroke.Paint.Kind = pkPattern) or
    ((E.Fill.Kind <> pkNone) and (E.Stroke.Paint.Kind <> pkNone)));
  if layer then BeginLayer(-1, alpha, True);
  path := BuildPath(E.Path, E.FillRule);
  try
    if layer then alpha := 1;
    FillWith(E.Fill, path, b, alpha);
    StrokeWith(E.Stroke, path, b, alpha);
  finally
    GdipDeletePath(path);
    if layer then EndLayer;
  end;
end;

function TGdipRenderer.GetFamily(const Name: string; var Style: Integer): GpFontFamily;
var
  i: Integer;
  key: string;
  ws: WideString;
  fam: GpFontFamily;
  ok: BOOL;
  owned: Boolean;
begin
  key := LowerCase(Name);
  fam := nil;
  owned := False;
  for i := 0 to High(Fonts) do
    if Fonts[i].Key = key then begin fam := Fonts[i].Family; Break; end;
  if fam = nil then
  begin
    ws := UTF8Decode(Name);
    if (ws = '') or (GdipCreateFontFamilyFromName(PWideChar(ws), nil, fam) <> 0) then
    begin
      fam := nil;
      // common PostScript / Mac names
      if Pos('times', key) > 0 then ws := 'Times New Roman'
      else if (Pos('courier', key) > 0) or (Pos('mono', key) > 0) then ws := 'Courier New'
      else if Pos('symbol', key) > 0 then ws := 'Symbol'
      else ws := 'Arial';
      if GdipCreateFontFamilyFromName(PWideChar(ws), nil, fam) <> 0 then fam := nil;
    end;
    owned := fam <> nil;
    if fam = nil then GdipGetGenericFontFamilySansSerif(fam);
    SetLength(Fonts, Length(Fonts) + 1);
    Fonts[High(Fonts)].Key := key;
    Fonts[High(Fonts)].Family := fam;
    Fonts[High(Fonts)].Owned := owned;
  end;
  Result := fam;
  if Result = nil then Exit;
  ok := False;
  GdipIsStyleAvailable(Result, Style, ok);
  if not ok then
  begin
    Style := Style and not (FontStyleBold or FontStyleItalic);
    GdipIsStyleAvailable(Result, Style, ok);
    if not ok then Style := FontStyleBold;
  end;
end;

function TGdipRenderer.FontStyle(const F: TXVFont): Integer;
begin
  Result := FontStyleRegular;
  if F.Weight >= 600 then Result := Result or FontStyleBold;
  if F.Italic then Result := Result or FontStyleItalic;
  if F.Underline then Result := Result or FontStyleUnderline;
  if F.Strike then Result := Result or FontStyleStrikeout;
end;

function TGdipRenderer.Measure(const Font: TXVFont; const S: string): Double;
const
  REF = 100;
var
  st, i: Integer;
  fam: GpFontFamily;
  key: string;
  f: GpFont;
  ws: WideString;
  r, box: TGPRectF;
begin
  Result := 0;
  if S = '' then Exit;
  st := FontStyle(Font) and (FontStyleBold or FontStyleItalic);
  fam := GetFamily(Font.Family, st);
  if fam = nil then Exit(Length(S) * 0.5 * Font.Size);
  key := LowerCase(Font.Family) + '|' + IntToStr(st);
  f := nil;
  for i := 0 to High(MFonts) do
    if MFonts[i].Key = key then begin f := MFonts[i].Font; Break; end;
  if f = nil then
  begin
    GdipCreateFont(fam, REF, st, UnitPixel, f);
    SetLength(MFonts, Length(MFonts) + 1);
    MFonts[High(MFonts)].Key := key;
    MFonts[High(MFonts)].Font := f;
  end;
  if f = nil then Exit(Length(S) * 0.5 * Font.Size);
  ws := UTF8Decode(S);
  FillChar(r, SizeOf(r), 0);
  FillChar(box, SizeOf(box), 0);
  GdipMeasureString(MeasureG, PWideChar(ws), Length(ws), f, r, Format, box, nil, nil);
  Result := box.Width * Font.Size / REF;
end;

procedure TGdipRenderer.DrawTextEl(const E: TXVElement; const M: TXVMatrix);
var
  st, k: Integer;
  fam: GpFontFamily;
  asc, desc, em: Word;
  ascent, descent, y0, sz: Double;
  ws: WideString;
  r: TGPRectF;
  path: GpPath;
  gm: GpMatrix;
  b: TXVRect;
  pb: TGPRectF;
  ch: TStringArray;
  scale: Double;
begin
  if (E.Text = '') or ((E.Fill.Kind = pkNone) and (E.Stroke.Paint.Kind = pkNone)) then Exit;
  if (E.Font.Size <= 0) or (Abs(M.Det) < 1e-300) then Exit;
  st := FontStyle(E.Font);
  fam := GetFamily(E.Font.Family, st);
  if fam = nil then Exit;
  asc := 0; desc := 0; em := 0;
  GdipGetCellAscent(fam, st and 3, asc);
  GdipGetCellDescent(fam, st and 3, desc);
  GdipGetEmHeight(fam, st and 3, em);
  if em = 0 then em := 2048;
  // GDI+ outlines are poor for very small em sizes: build the glyphs at a
  // reference size and scale them into place
  sz := E.Font.Size;
  scale := 1;
  if sz < 64 then
  begin
    scale := sz / 64;
    sz := 64;
  end;
  ascent := sz * asc / em;
  descent := sz * desc / em;
  case E.Baseline of
    tbTop: y0 := 0;
    tbMiddle: y0 := -(ascent + descent) / 2;
    tbBottom: y0 := -(ascent + descent);
  else
    y0 := -ascent;
  end;
  path := nil;
  GdipCreatePath(FillModeWinding, path);
  try
    if Length(E.CharX) > 0 then
    begin
      ch := XVUtf8Chars(E.Text);
      for k := 0 to High(ch) do
      begin
        ws := UTF8Decode(ch[k]);
        r.Y := y0; r.Width := 0; r.Height := 0;
        if k <= High(E.CharX) then r.X := E.CharX[k] / scale else r.X := E.CharX[High(E.CharX)] / scale;
        GdipAddPathString(path, PWideChar(ws), Length(ws), fam, st, sz, r, Format);
      end;
    end
    else
    begin
      ws := UTF8Decode(E.Text);
      r.X := 0; r.Y := y0; r.Width := 0; r.Height := 0;
      GdipAddPathString(path, PWideChar(ws), Length(ws), fam, st, sz, r, Format);
    end;
    gm := MakeMatrix(XVMul(M, TXVMatrix.Scale(scale, scale)));
    GdipTransformPath(path, gm);
    GdipDeleteMatrix(gm);
    FillChar(pb, SizeOf(pb), 0);
    GdipGetPathWorldBounds(path, @pb, nil, nil);
    b := XVRect(pb.X, pb.Y, pb.X + pb.Width, pb.Y + pb.Height);
    FillWith(E.Fill, path, b, E.Opacity);
    StrokeWith(E.Stroke, path, b, E.Opacity);
  finally
    GdipDeletePath(path);
  end;
end;

procedure TGdipRenderer.DrawImageEl(const E: TXVElement);
var
  bmp: GpBitmap;
  gm: GpMatrix;
  attr: GpImageAttributes;
  cm: TColorMatrix;
  i: Integer;
  iw, ih: Integer;
  sc: Double;
begin
  bmp := ImageBitmap(E.Image);
  if bmp = nil then Exit;
  iw := Doc.Images[E.Image].W; ih := Doc.Images[E.Image].H;
  gm := MakeMatrix(XVMul(View, E.Matrix));
  GdipSetWorldTransform(G, gm);
  GdipDeleteMatrix(gm);
  attr := nil;
  GdipCreateImageAttributes(attr);
  GdipSetImageAttributesWrapMode(attr, WrapModeTileFlipXY, 0, False);
  if E.Opacity < 0.999 then
  begin
    FillChar(cm, SizeOf(cm), 0);
    for i := 0 to 4 do cm[i, i] := 1;
    cm[3, 3] := Clamp01(E.Opacity);
    GdipSetImageAttributesColorMatrix(attr, ColorAdjustTypeDefault, True, @cm, nil, ColorMatrixFlagsDefault);
  end;
  // strongly enlarged small images (icons, patterns of pixels) stay sharp
  sc := XVMul(View, E.Matrix).ScaleFactor;
  if sc > 4 then GdipSetInterpolationMode(G, InterpolationModeNearestNeighbor);
  GdipDrawImageRectRect(G, bmp, 0, 0, iw, ih, 0, 0, iw, ih, UnitPixel, attr, nil, nil);
  if sc > 4 then GdipSetInterpolationMode(G, InterpolationModeHighQualityBicubic);
  GdipDisposeImageAttributes(attr);
  GdipSetWorldTransform(G, ViewM);
end;

function TGdipRenderer.Run(var Raster: TXVRaster; const Opt: TXVRenderOptions): Boolean;
var
  i: Integer;
  bg: TXVColor;
  br: GpBrush;
begin
  Result := False;
  SetLength(Raster.Px, W * H);
  bg := Opt.Background;
  XVFillRaster(Raster, bg);
  XVPremultiply(Raster);
  MainBmp := nil;
  if GdipCreateBitmapFromScan0(W, H, W * 4, PixelFormat32bppPARGB, @Raster.Px[0], MainBmp) <> 0 then Exit;
  try
    G := nil;
    GdipGetImageGraphicsContext(MainBmp, G);
    if G = nil then Exit;
    try
      SetupGraphics(G);
      if Opt.UseDocBackground and ((Doc.Background shr 24) <> 0) then
      begin
        // the page colour over the view box
        br := nil;
        GdipCreateSolidFill(Doc.Background, br);
        with Doc.ViewBox do GdipFillRectangle(G, br, Left, Top, Right - Left, Bottom - Top);
        GdipDeleteBrush(br);
      end;
      Layout := XVLayoutTexts(Doc, Measure);
      for i := 0 to Doc.Count - 1 do
        case Doc.Elements[i].Kind of
          ekGroup: BeginLayer(Doc.Elements[i].Clip, Doc.Elements[i].Opacity, False);
          ekGroupEnd: EndLayer;
          ekPath: DrawPathEl(Doc.Elements[i]);
          ekText: DrawTextEl(Doc.Elements[i], Layout[i]);
          ekImage: DrawImageEl(Doc.Elements[i]);
        end;
      while Length(Stack) > 0 do EndLayer;
      Result := True;
    finally
      GdipDeleteGraphics(G);
    end;
  finally
    GdipDisposeImage(MainBmp);
  end;
  XVUnpremultiply(Raster);
end;

function XVRenderWithGdiPlus(Doc: TXVDocument; var Raster: TXVRaster; const Opt: TXVRenderOptions): Boolean;
var R: TGdipRenderer;
begin
  Result := False;
  if (Raster.W <= 0) or (Raster.H <= 0) then Exit;
  if not XVGdipStart then Exit;
  R := TGdipRenderer.Create(Doc, Raster.W, Raster.H, Opt);
  try
    Result := R.Run(Raster, Opt);
  finally
    R.Free;
  end;
end;

{$ELSE}

function XVRenderWithGdiPlus(Doc: TXVDocument; var Raster: TXVRaster; const Opt: TXVRenderOptions): Boolean;
begin
  Result := False;
end;

{$ENDIF}

end.
