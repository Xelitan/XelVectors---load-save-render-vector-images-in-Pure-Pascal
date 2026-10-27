unit XVGdiPlusApi;

{$mode delphi}{$H+}

// XelVectors - the part of the GDI+ flat API the renderer uses.

interface

{$IFDEF MSWINDOWS}

uses
  Windows;

type
  GpStatus = Integer;
  GpGraphics = Pointer;
  GpPath = Pointer;
  GpBrush = Pointer;
  GpPen = Pointer;
  GpImage = Pointer;
  GpBitmap = Pointer;
  GpMatrix = Pointer;
  GpFontFamily = Pointer;
  GpFont = Pointer;
  GpStringFormat = Pointer;
  GpImageAttributes = Pointer;
  ARGB = Cardinal;
  PARGB = ^ARGB;

  TGPPointF = record
    X, Y: Single;
  end;
  PGPPointF = ^TGPPointF;

  TGPRectF = record
    X, Y, Width, Height: Single;
  end;
  PGPRectF = ^TGPRectF;

  TGdiplusStartupInput = record
    GdiplusVersion: Cardinal;
    DebugEventCallback: Pointer;
    SuppressBackgroundThread: BOOL;
    SuppressExternalCodecs: BOOL;
  end;
  PGdiplusStartupInput = ^TGdiplusStartupInput;

  TColorMatrix = array[0..4, 0..4] of Single;
  PColorMatrix = ^TColorMatrix;

const
  GDIP_DLL = 'gdiplus.dll';

  PixelFormat32bppARGB = $0026200A;
  PixelFormat32bppPARGB = $000E200B;

  FillModeAlternate = 0;
  FillModeWinding = 1;

  SmoothingModeNone = 3;
  SmoothingModeAntiAlias = 4;
  PixelOffsetModeHalf = 4;
  PixelOffsetModeNone = 3;
  InterpolationModeBilinear = 3;
  InterpolationModeHighQualityBicubic = 7;
  InterpolationModeNearestNeighbor = 5;
  CompositingQualityHighQuality = 2;
  CompositingQualityAssumeLinear = 4;
  TextRenderingHintAntiAlias = 4;

  WrapModeTile = 0;
  WrapModeTileFlipX = 1;
  WrapModeTileFlipXY = 3;
  WrapModeClamp = 4;

  UnitWorld = 0;
  UnitPixel = 2;

  LineCapFlat = 0;
  LineCapSquare = 1;
  LineCapRound = 2;
  DashCapFlat = 0;
  DashCapRound = 2;
  LineJoinMiter = 0;
  LineJoinBevel = 1;
  LineJoinRound = 2;
  LineJoinMiterClipped = 3;

  CombineModeReplace = 0;
  CombineModeIntersect = 1;

  FontStyleRegular = 0;
  FontStyleBold = 1;
  FontStyleItalic = 2;
  FontStyleUnderline = 4;
  FontStyleStrikeout = 8;

  StringFormatFlagsMeasureTrailingSpaces = $00000800;
  StringFormatFlagsNoWrap = $00001000;
  StringFormatFlagsNoClip = $00004000;

  MatrixOrderPrepend = 0;
  MatrixOrderAppend = 1;

  ColorAdjustTypeDefault = 0;
  ColorAdjustTypeBitmap = 1;
  ColorMatrixFlagsDefault = 0;

function GdiplusStartup(out token: ULONG_PTR; input: PGdiplusStartupInput; output: Pointer): GpStatus; stdcall; external GDIP_DLL;
procedure GdiplusShutdown(token: ULONG_PTR); stdcall; external GDIP_DLL;

function GdipCreateBitmapFromScan0(width, height, stride, format: Integer; scan0: Pointer; out bitmap: GpBitmap): GpStatus; stdcall; external GDIP_DLL;
function GdipGetImageGraphicsContext(image: GpImage; out graphics: GpGraphics): GpStatus; stdcall; external GDIP_DLL;
function GdipDeleteGraphics(graphics: GpGraphics): GpStatus; stdcall; external GDIP_DLL;
function GdipDisposeImage(image: GpImage): GpStatus; stdcall; external GDIP_DLL;
function GdipGraphicsClear(graphics: GpGraphics; color: ARGB): GpStatus; stdcall; external GDIP_DLL;

function GdipSetSmoothingMode(graphics: GpGraphics; mode: Integer): GpStatus; stdcall; external GDIP_DLL;
function GdipSetPixelOffsetMode(graphics: GpGraphics; mode: Integer): GpStatus; stdcall; external GDIP_DLL;
function GdipSetTextRenderingHint(graphics: GpGraphics; mode: Integer): GpStatus; stdcall; external GDIP_DLL;
function GdipSetInterpolationMode(graphics: GpGraphics; mode: Integer): GpStatus; stdcall; external GDIP_DLL;
function GdipSetCompositingQuality(graphics: GpGraphics; mode: Integer): GpStatus; stdcall; external GDIP_DLL;

function GdipCreateMatrix2(m11, m12, m21, m22, dx, dy: Single; out matrix: GpMatrix): GpStatus; stdcall; external GDIP_DLL;
function GdipDeleteMatrix(matrix: GpMatrix): GpStatus; stdcall; external GDIP_DLL;
function GdipSetWorldTransform(graphics: GpGraphics; matrix: GpMatrix): GpStatus; stdcall; external GDIP_DLL;
function GdipResetWorldTransform(graphics: GpGraphics): GpStatus; stdcall; external GDIP_DLL;

function GdipCreatePath(brushMode: Integer; out path: GpPath): GpStatus; stdcall; external GDIP_DLL;
function GdipDeletePath(path: GpPath): GpStatus; stdcall; external GDIP_DLL;
function GdipStartPathFigure(path: GpPath): GpStatus; stdcall; external GDIP_DLL;
function GdipClosePathFigure(path: GpPath): GpStatus; stdcall; external GDIP_DLL;
function GdipAddPathLine(path: GpPath; x1, y1, x2, y2: Single): GpStatus; stdcall; external GDIP_DLL;
function GdipAddPathBezier(path: GpPath; x1, y1, x2, y2, x3, y3, x4, y4: Single): GpStatus; stdcall; external GDIP_DLL;
function GdipAddPathEllipse(path: GpPath; x, y, width, height: Single): GpStatus; stdcall; external GDIP_DLL;
function GdipAddPathRectangle(path: GpPath; x, y, width, height: Single): GpStatus; stdcall; external GDIP_DLL;
function GdipSetPathFillMode(path: GpPath; fillmode: Integer): GpStatus; stdcall; external GDIP_DLL;
function GdipTransformPath(path: GpPath; matrix: GpMatrix): GpStatus; stdcall; external GDIP_DLL;
function GdipGetPathWorldBounds(path: GpPath; bounds: PGPRectF; matrix: GpMatrix; pen: GpPen): GpStatus; stdcall; external GDIP_DLL;
function GdipGetPointCount(path: GpPath; out count: Integer): GpStatus; stdcall; external GDIP_DLL;

function GdipCreateSolidFill(color: ARGB; out brush: GpBrush): GpStatus; stdcall; external GDIP_DLL;
function GdipDeleteBrush(brush: GpBrush): GpStatus; stdcall; external GDIP_DLL;
function GdipCreateLineBrush(const point1, point2: TGPPointF; color1, color2: ARGB; wrapMode: Integer; out lineGradient: GpBrush): GpStatus; stdcall; external GDIP_DLL;
function GdipSetLinePresetBlend(brush: GpBrush; blend: PARGB; positions: PSingle; count: Integer): GpStatus; stdcall; external GDIP_DLL;
function GdipSetLineTransform(brush: GpBrush; matrix: GpMatrix): GpStatus; stdcall; external GDIP_DLL;
function GdipMultiplyLineTransform(brush: GpBrush; matrix: GpMatrix; order: Integer): GpStatus; stdcall; external GDIP_DLL;
function GdipSetLineGammaCorrection(brush: GpBrush; useGammaCorrection: BOOL): GpStatus; stdcall; external GDIP_DLL;
function GdipCreatePathGradientFromPath(path: GpPath; out polyGradient: GpBrush): GpStatus; stdcall; external GDIP_DLL;
function GdipSetPathGradientCenterPoint(brush: GpBrush; const points: TGPPointF): GpStatus; stdcall; external GDIP_DLL;
function GdipSetPathGradientPresetBlend(brush: GpBrush; blend: PARGB; positions: PSingle; count: Integer): GpStatus; stdcall; external GDIP_DLL;
function GdipSetPathGradientCenterColor(brush: GpBrush; colors: ARGB): GpStatus; stdcall; external GDIP_DLL;
function GdipSetPathGradientSurroundColorsWithCount(brush: GpBrush; color: PARGB; var count: Integer): GpStatus; stdcall; external GDIP_DLL;
function GdipCreateTexture(image: GpImage; wrapmode: Integer; out texture: GpBrush): GpStatus; stdcall; external GDIP_DLL;
function GdipSetTextureTransform(brush: GpBrush; matrix: GpMatrix): GpStatus; stdcall; external GDIP_DLL;

function GdipCreatePen1(color: ARGB; width: Single; aUnit: Integer; out pen: GpPen): GpStatus; stdcall; external GDIP_DLL;
function GdipCreatePen2(brush: GpBrush; width: Single; aUnit: Integer; out pen: GpPen): GpStatus; stdcall; external GDIP_DLL;
function GdipDeletePen(pen: GpPen): GpStatus; stdcall; external GDIP_DLL;
function GdipSetPenLineCap197819(pen: GpPen; startCap, endCap, dashCap: Integer): GpStatus; stdcall; external GDIP_DLL;
function GdipSetPenLineJoin(pen: GpPen; lineJoin: Integer): GpStatus; stdcall; external GDIP_DLL;
function GdipSetPenMiterLimit(pen: GpPen; miterLimit: Single): GpStatus; stdcall; external GDIP_DLL;
function GdipSetPenDashArray(pen: GpPen; dash: PSingle; count: Integer): GpStatus; stdcall; external GDIP_DLL;
function GdipSetPenDashOffset(pen: GpPen; offset: Single): GpStatus; stdcall; external GDIP_DLL;

function GdipFillPath(graphics: GpGraphics; brush: GpBrush; path: GpPath): GpStatus; stdcall; external GDIP_DLL;
function GdipDrawPath(graphics: GpGraphics; pen: GpPen; path: GpPath): GpStatus; stdcall; external GDIP_DLL;
function GdipFillRectangle(graphics: GpGraphics; brush: GpBrush; x, y, width, height: Single): GpStatus; stdcall; external GDIP_DLL;

function GdipSetClipPath(graphics: GpGraphics; path: GpPath; combineMode: Integer): GpStatus; stdcall; external GDIP_DLL;
function GdipResetClip(graphics: GpGraphics): GpStatus; stdcall; external GDIP_DLL;
function GdipSaveGraphics(graphics: GpGraphics; out state: Cardinal): GpStatus; stdcall; external GDIP_DLL;
function GdipRestoreGraphics(graphics: GpGraphics; state: Cardinal): GpStatus; stdcall; external GDIP_DLL;

function GdipDrawImageRectRect(graphics: GpGraphics; image: GpImage; dstx, dsty, dstwidth, dstheight,
  srcx, srcy, srcwidth, srcheight: Single; srcUnit: Integer; imageAttributes: GpImageAttributes;
  callback: Pointer; callbackData: Pointer): GpStatus; stdcall; external GDIP_DLL;
function GdipCreateImageAttributes(out imageattr: GpImageAttributes): GpStatus; stdcall; external GDIP_DLL;
function GdipDisposeImageAttributes(imageattr: GpImageAttributes): GpStatus; stdcall; external GDIP_DLL;
function GdipSetImageAttributesColorMatrix(imageattr: GpImageAttributes; aType: Integer; enableFlag: BOOL;
  colorMatrix: PColorMatrix; grayMatrix: PColorMatrix; flags: Integer): GpStatus; stdcall; external GDIP_DLL;
function GdipSetImageAttributesWrapMode(imageAttr: GpImageAttributes; wrap: Integer; argb: ARGB; clamp: BOOL): GpStatus; stdcall; external GDIP_DLL;

function GdipCreateFontFamilyFromName(name: PWideChar; fontCollection: Pointer; out fontFamily: GpFontFamily): GpStatus; stdcall; external GDIP_DLL;
function GdipDeleteFontFamily(fontFamily: GpFontFamily): GpStatus; stdcall; external GDIP_DLL;
function GdipGetGenericFontFamilySansSerif(out nativeFamily: GpFontFamily): GpStatus; stdcall; external GDIP_DLL;
function GdipIsStyleAvailable(family: GpFontFamily; style: Integer; out isStyleAvailable: BOOL): GpStatus; stdcall; external GDIP_DLL;
function GdipGetCellAscent(family: GpFontFamily; style: Integer; out CellAscent: Word): GpStatus; stdcall; external GDIP_DLL;
function GdipGetCellDescent(family: GpFontFamily; style: Integer; out CellDescent: Word): GpStatus; stdcall; external GDIP_DLL;
function GdipGetEmHeight(family: GpFontFamily; style: Integer; out EmHeight: Word): GpStatus; stdcall; external GDIP_DLL;
function GdipCreateFont(fontFamily: GpFontFamily; emSize: Single; style: Integer; aUnit: Integer; out font: GpFont): GpStatus; stdcall; external GDIP_DLL;
function GdipDeleteFont(font: GpFont): GpStatus; stdcall; external GDIP_DLL;
function GdipStringFormatGetGenericTypographic(out format: GpStringFormat): GpStatus; stdcall; external GDIP_DLL;
function GdipCloneStringFormat(format: GpStringFormat; out newFormat: GpStringFormat): GpStatus; stdcall; external GDIP_DLL;
function GdipSetStringFormatFlags(format: GpStringFormat; flags: Integer): GpStatus; stdcall; external GDIP_DLL;
function GdipDeleteStringFormat(format: GpStringFormat): GpStatus; stdcall; external GDIP_DLL;
function GdipAddPathString(path: GpPath; str: PWideChar; length: Integer; family: GpFontFamily; style: Integer;
  emSize: Single; const layoutRect: TGPRectF; format: GpStringFormat): GpStatus; stdcall; external GDIP_DLL;
function GdipMeasureString(graphics: GpGraphics; str: PWideChar; length: Integer; font: GpFont;
  const layoutRect: TGPRectF; stringFormat: GpStringFormat; out boundingBox: TGPRectF;
  codepointsFitted: PInteger; linesFilled: PInteger): GpStatus; stdcall; external GDIP_DLL;

// starts GDI+ once for the process (shut down at exit)
function XVGdipStart: Boolean;

{$ENDIF}

implementation

{$IFDEF MSWINDOWS}

var
  GToken: ULONG_PTR = 0;
  GStarted: Boolean = False;

function XVGdipStart: Boolean;
var inp: TGdiplusStartupInput;
begin
  if not GStarted then
  begin
    FillChar(inp, SizeOf(inp), 0);
    inp.GdiplusVersion := 1;
    GStarted := GdiplusStartup(GToken, @inp, nil) = 0;
  end;
  Result := GStarted;
end;

initialization

finalization
  if GStarted then GdiplusShutdown(GToken);

{$ENDIF}

end.
