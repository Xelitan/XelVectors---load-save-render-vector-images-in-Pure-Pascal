unit XVModel;

{$mode delphi}{$H+}
{$R-}{$Q-}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	XelVectors - in-memory vector document model                  //
// Version:	0.1                                                           //
// Date:	22-OCT-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64, Linux64, Free Pascal                                   //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// Every reader turns its file into the same flat structure:
//
//   TXVDocument
//     Elements[]   paths, texts, images and group brackets, in painting order
//     Gradients[]  linear / radial gradients referenced by paints
//     Patterns[]   tiled images referenced by paints
//     Images[]     ARGB rasters (images and pattern tiles)
//     Clips[]      clip outlines referenced by groups
//
// Geometry is stored in document units with the y axis pointing down; the
// document's ViewBox is the part of that space that forms the picture and
// Width / Height its natural size in pixels (96 dpi). Transforms of the source
// format are applied to the path points while reading; texts and images keep a
// matrix because they cannot be flattened.

interface

uses
  SysUtils, Classes, Math, XelInflate;

const
  XV_PX_PER_INCH = 96.0;
  XV_PX_PER_MM = 96.0 / 25.4;
  XV_PX_PER_PT = 96.0 / 72.0;

  XV_BLACK = Cardinal($FF000000);
  XV_WHITE = Cardinal($FFFFFFFF);
  XV_TRANSPARENT = Cardinal($00000000);

type
  EXVError = class(Exception);

  // $AARRGGBB, not premultiplied
  TXVColor = Cardinal;

  TXVPoint = record
    X, Y: Double;
  end;
  PXVPoint = ^TXVPoint;
  TXVPoints = array of TXVPoint;
  TXVDoubles = array of Double;

  TXVRect = record
    Left, Top, Right, Bottom: Double;
    function Width: Double;
    function Height: Double;
    function IsEmpty: Boolean;
  end;

  // SVG order: x' = A x + C y + E,  y' = B x + D y + F
  TXVMatrix = record
    A, B, C, D, E, F: Double;
    class function Identity: TXVMatrix; static;
    class function Make(AA, AB, AC, AD, AE, AF: Double): TXVMatrix; static;
    class function Translate(X, Y: Double): TXVMatrix; static;
    class function Scale(SX, SY: Double): TXVMatrix; static;
    class function Rotate(Rad: Double): TXVMatrix; static;
    class function SkewX(Rad: Double): TXVMatrix; static;
    class function SkewY(Rad: Double): TXVMatrix; static;
    function Apply(const P: TXVPoint): TXVPoint; overload;
    function Apply(X, Y: Double): TXVPoint; overload;
    procedure ApplyXY(var X, Y: Double);
    function ApplyVec(X, Y: Double): TXVPoint;
    function Det: Double;
    function Invert: TXVMatrix;
    function IsIdentity: Boolean;
    function ScaleFactor: Double;          // sqrt(|det|): linear scale
    function RotationAngle: Double;        // angle of the x axis, radians
  end;

  TXVPathCmd = (pcMoveTo, pcLineTo, pcCubicTo, pcClose);

  // A path: a list of commands and the points they use (MoveTo / LineTo one
  // point, CubicTo three: two controls and the end point, Close none).
  // NCmd / NPt are the used lengths; the arrays may be longer.
  TXVPath = record
    Cmds: array of TXVPathCmd;
    Pts: array of TXVPoint;
    NCmd, NPt: Integer;
    FStart, FCur: TXVPoint;
    FOpen: Boolean;                       // a current point exists
    procedure Clear;
    procedure MoveTo(X, Y: Double);
    procedure LineTo(X, Y: Double);
    procedure CubicTo(X1, Y1, X2, Y2, X, Y: Double);
    procedure QuadTo(X1, Y1, X, Y: Double);
    procedure ConicTo(X1, Y1, X, Y, W: Double);
    // SVG elliptical arc from the current point to (X, Y)
    procedure ArcTo(RX, RY, XRotDeg: Double; LargeArc, Sweep: Boolean; X, Y: Double);
    // Elliptic arc around (CX, CY): radii, x-axis rotation, start angle and
    // sweep in radians (positive = towards +y). Lead: 0 continue from the
    // last point (no segment to the first arc point), 1 MoveTo the first point,
    // 2 LineTo the first point.
    procedure ArcCenter(CX, CY, RX, RY, RotRad, StartRad, SweepRad: Double; Lead: Integer);
    procedure Close;
    procedure AddRect(X, Y, W, H: Double);
    procedure AddRoundRect(X, Y, W, H, RX, RY: Double);
    procedure AddEllipse(CX, CY, RX, RY: Double);
    procedure AddPolygon(const P: array of TXVPoint; Closed: Boolean);
    procedure Append(const P: TXVPath);
    procedure Transform(const M: TXVMatrix);
    function Bounds(out R: TXVRect): Boolean;
    function IsEmpty: Boolean;
    function HasCurrent: Boolean;
    function CurrentPoint: TXVPoint;
    function StartPoint: TXVPoint;
    procedure Compact;
    function Copy: TXVPath;
  end;
  PXVPath = ^TXVPath;

  TXVFillRule = (frNonZero, frEvenOdd);
  TXVLineCap = (lcButt, lcRound, lcSquare);
  TXVLineJoin = (ljMiter, ljRound, ljBevel);

  TXVGradStop = record
    Offset: Double;
    Color: TXVColor;
  end;

  TXVGradientKind = (gkLinear, gkRadial);
  TXVSpread = (spPad, spReflect, spRepeat);

  TXVGradient = record
    Kind: TXVGradientKind;
    Spread: TXVSpread;
    X1, Y1, X2, Y2: Double;               // linear: start and end
    CX, CY, R, FX, FY: Double;            // radial: centre, radius, focus
    Matrix: TXVMatrix;                    // gradient space -> document space
    Stops: array of TXVGradStop;
  end;

  // A repeated image tile; the tile covers 0..W x 0..H of its own space.
  TXVPattern = record
    Image: Integer;
    Matrix: TXVMatrix;                    // tile pixel space -> document space
    // the tile is laid out in output pixels whatever the zoom (GDI hatches,
    // GOCA / CGM pattern sets); Matrix then only places its origin
    DeviceTile: Boolean;
  end;

  TXVPaintKind = (pkNone, pkSolid, pkGradient, pkPattern);

  TXVPaint = record
    Kind: TXVPaintKind;
    Color: TXVColor;                      // solid colour; the average for the others
    Index: Integer;                       // gradient or pattern index
  end;

  TXVStroke = record
    Paint: TXVPaint;
    Width: Double;                        // document units, 0 = one device pixel
    Cap: TXVLineCap;
    Join: TXVLineJoin;
    MiterLimit: Double;
    Dashes: TXVDoubles;                   // document units, on / off
    DashOffset: Double;
  end;

  TXVImage = record
    W, H: Integer;
    Px: array of Cardinal;                // $AARRGGBB, top-down, not premultiplied
  end;
  PXVImage = ^TXVImage;
  TXVRaster = TXVImage;

  TXVClip = record
    Path: TXVPath;
    Rule: TXVFillRule;
  end;

  TXVTextAnchor = (taStart, taMiddle, taEnd);
  TXVTextBaseline = (tbAlphabetic, tbTop, tbMiddle, tbBottom);

  TXVFont = record
    Family: string;
    Size: Double;                         // em size in text space units
    Weight: Integer;                      // 100..900, 400 normal, 700 bold
    Italic, Underline, Strike: Boolean;
  end;

  TXVElementKind = (ekPath, ekText, ekImage, ekGroup, ekGroupEnd);

  TXVElement = record
    Kind: TXVElementKind;
    Name: string;                         // id / layer / object name if known
    Opacity: Double;                      // 0..1, groups: of the whole group
    // ekPath (fill and stroke also paint texts)
    Path: TXVPath;
    Fill: TXVPaint;
    FillRule: TXVFillRule;
    Stroke: TXVStroke;
    // ekGroup
    Clip: Integer;                        // -1 none
    // ekText: Matrix maps text space (origin at the start of the baseline,
    // x along the baseline, y down) to the document; ekImage: Matrix maps
    // the image's pixel space (0..W x 0..H) to the document
    Matrix: TXVMatrix;
    Text: string;                         // UTF-8
    Font: TXVFont;
    Anchor: TXVTextAnchor;
    Baseline: TXVTextBaseline;
    CharX: TXVDoubles;                    // optional x of every character, text space
    // the text starts where the previous text element ended (one SVG text
    // chunk); Matrix.E / F is then a shift in document units
    Continued: Boolean;
    Image: Integer;
  end;
  PXVElement = ^TXVElement;

  TXVDocument = class;

  TXVDetectFunc = function(const Data: TBytes): Boolean;
  TXVReadFunc = procedure(Doc: TXVDocument; const Data: TBytes);
  TXVWriteFunc = procedure(Doc: TXVDocument; Stream: TStream);

  { TXVDocument }

  TXVDocument = class
  private
    FCount: Integer;
    function GetElement(Index: Integer): PXVElement;
  public
    Width, Height: Double;                // natural size, pixels at 96 dpi
    ViewBox: TXVRect;                     // document space shown in the picture
    Background: TXVColor;                 // page colour, 0 = none
    Elements: array of TXVElement;
    Gradients: array of TXVGradient;
    Patterns: array of TXVPattern;
    Images: array of TXVImage;
    Clips: array of TXVClip;
    SourceFormat: string;
    SourceFile: string;                   // the file being read, for files it refers to (images)
    Title: string;
    PageCount: Integer;                   // pages in the source (one is loaded)
    LoadPage: Integer;                    // page to load (0-based), for multi-page formats
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    // building
    function NewElement(AKind: TXVElementKind): Integer;
    function AddPath(const P: TXVPath; const AFill: TXVPaint; const AStroke: TXVStroke;
      ARule: TXVFillRule = frNonZero; AOpacity: Double = 1): Integer;
    function AddText(const AText: string; const AFont: TXVFont; const M: TXVMatrix;
      const AFill: TXVPaint; AAnchor: TXVTextAnchor = taStart): Integer;
    function AddImage(AImage: Integer; const M: TXVMatrix; AOpacity: Double = 1): Integer;
    function BeginGroup(AClip: Integer = -1; AOpacity: Double = 1): Integer;
    procedure EndGroup;
    // replaces the element list (readers that reorder what they built)
    procedure SetElements(const AElements: array of TXVElement);
    procedure Truncate(ACount: Integer);
    // appends the elements of another document, transformed by M (its
    // gradients, patterns, images and clips are copied along)
    procedure AppendDocument(Other: TXVDocument; const M: TXVMatrix);
    // the other document's view box placed into the rectangle, clipped to it
    procedure AppendDocumentInto(Other: TXVDocument; X, Y, W, H: Double; const M: TXVMatrix);
    function AddGradient(const G: TXVGradient): Integer;
    function AddPattern(AImage: Integer; const M: TXVMatrix; ADeviceTile: Boolean = False): Integer;
    function AddImageData(const Img: TXVImage): Integer;
    function AddClip(const P: TXVPath; ARule: TXVFillRule = frNonZero): Integer;
    // geometry
    function ContentBounds(out R: TXVRect): Boolean;
    procedure SetPageSize(AWidth, AHeight: Double);         // ViewBox 0 0 W H
    procedure FitToContent(Margin: Double = 0);
    procedure Transform(const M: TXVMatrix);                // everything
    // input / output through the registered readers and writers
    procedure LoadFromBytes(const Data: TBytes; const FileNameHint: string = '');
    procedure LoadFromStream(Stream: TStream; const FileNameHint: string = '');
    procedure LoadFromFile(const FileName: string);
    procedure SaveToStream(Stream: TStream; const Format: string);
    procedure SaveToFile(const FileName: string);
    property Count: Integer read FCount;
    property Items[Index: Integer]: PXVElement read GetElement; default;
  end;

// ---- colours ----
function XVRGB(R, G, B: Byte): TXVColor;
function XVRGBA(R, G, B, A: Byte): TXVColor;
function XVColorAlpha(C: TXVColor): Byte;
function XVColorR(C: TXVColor): Byte;
function XVColorG(C: TXVColor): Byte;
function XVColorB(C: TXVColor): Byte;
function XVWithAlpha(C: TXVColor; A: Byte): TXVColor;
function XVMulAlpha(C: TXVColor; Opacity: Double): TXVColor;
function XVLerpColor(C1, C2: TXVColor; T: Double): TXVColor;
function XVBGRToColor(BGR: Cardinal): TXVColor;               // Windows COLORREF $00BBGGRR
function XVCmykToColor(C, M, Y, K: Double): TXVColor;         // 0..1, naive
function XVHexColor(C: TXVColor): string;                     // #RRGGBB

// ---- paints ----
function XVNoPaint: TXVPaint;
function XVSolid(C: TXVColor): TXVPaint;
function XVGradientPaint(Index: Integer; AvgColor: TXVColor): TXVPaint;
function XVPatternPaint(Index: Integer; AvgColor: TXVColor): TXVPaint;
function XVNoStroke: TXVStroke;
function XVStroke(C: TXVColor; Width: Double): TXVStroke;
function XVDefaultFont: TXVFont;

// ---- matrices / points ----
function XVPt(X, Y: Double): TXVPoint;
function XVRect(L, T, R, B: Double): TXVRect;
function XVMul(const M1, M2: TXVMatrix): TXVMatrix;          // M2 first, then M1
procedure XVUnionRect(var R: TXVRect; var HaveR: Boolean; const X: TXVRect);

// ---- images ----
function XVNewImage(W, H: Integer; Fill: Cardinal = 0): TXVImage;
function XVImageAverage(const Img: TXVImage): TXVColor;

// ---- text helpers ----
function XVUtf8OfCode(CP: Cardinal): string;
function XVUtf16ToUtf8(const D: TBytes; Ofs, Len: Integer): string;
function XVCodePageToUtf8(const D: TBytes; Ofs, Len, CodePage: Integer): string;
function XVCharsetCodePage(CharSet: Integer): Integer;
function XVUtf8Chars(const S: string): TStringArray;     // one string per character
// estimated advance of a string in text units (Helvetica metrics)
function XVEstimateTextWidth(const Font: TXVFont; const S: string): Double;

// ---- numbers ----
function XVFmt(V: Double; Decimals: Integer = 3): string;  // '.' decimal, trimmed
function XVStrToFloat(const S: string; Def: Double = 0): Double;
function XVReadFileBytes(const FileName: string): TBytes;
function XVIsGzip(const Data: TBytes): Boolean;
function XVGunzip(const Data: TBytes): TBytes;

// ---- format registry ----
procedure XVRegisterReader(const AName, AExtensions: string; ADetect: TXVDetectFunc; ARead: TXVReadFunc);
procedure XVRegisterWriter(const AName, AExtensions: string; AWrite: TXVWriteFunc);
function XVReaderCount: Integer;
function XVReaderName(I: Integer): string;
function XVReaderExtensions(I: Integer): string;
function XVSupportedExtensions: string;        // '*.svg;*.wmf;...'
function XVDetectFormat(const Data: TBytes; const FileNameHint: string = ''): string;

implementation

type
  TXVReaderRec = record
    Name, Exts: string;
    Detect: TXVDetectFunc;
    Read: TXVReadFunc;
  end;
  TXVWriterRec = record
    Name, Exts: string;
    Write: TXVWriteFunc;
  end;

var
  GReaders: array of TXVReaderRec;
  GWriters: array of TXVWriterRec;

// ------------------------------ colours ------------------------------------

function XVRGB(R, G, B: Byte): TXVColor;
begin
  Result := $FF000000 or (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or B;
end;

function XVRGBA(R, G, B, A: Byte): TXVColor;
begin
  Result := (Cardinal(A) shl 24) or (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or B;
end;

function XVColorAlpha(C: TXVColor): Byte;
begin
  Result := C shr 24;
end;

function XVColorR(C: TXVColor): Byte;
begin
  Result := (C shr 16) and $FF;
end;

function XVColorG(C: TXVColor): Byte;
begin
  Result := (C shr 8) and $FF;
end;

function XVColorB(C: TXVColor): Byte;
begin
  Result := C and $FF;
end;

function XVWithAlpha(C: TXVColor; A: Byte): TXVColor;
begin
  Result := (C and $FFFFFF) or (Cardinal(A) shl 24);
end;

function XVMulAlpha(C: TXVColor; Opacity: Double): TXVColor;
var a: Integer;
begin
  if Opacity >= 1 then Exit(C);
  if Opacity <= 0 then Exit(C and $FFFFFF);
  a := Round((C shr 24) * Opacity);
  Result := (C and $FFFFFF) or (Cardinal(EnsureRange(a, 0, 255)) shl 24);
end;

function XVLerpColor(C1, C2: TXVColor; T: Double): TXVColor;

  function L(a, b: Integer): Cardinal;
  begin
    Result := EnsureRange(Round(a + (b - a) * T), 0, 255);
  end;

begin
  T := EnsureRange(T, 0, 1);
  Result := (L(C1 shr 24, C2 shr 24) shl 24) or (L((C1 shr 16) and $FF, (C2 shr 16) and $FF) shl 16) or
    (L((C1 shr 8) and $FF, (C2 shr 8) and $FF) shl 8) or L(C1 and $FF, C2 and $FF);
end;

function XVBGRToColor(BGR: Cardinal): TXVColor;
begin
  Result := $FF000000 or ((BGR and $FF) shl 16) or (BGR and $FF00) or ((BGR shr 16) and $FF);
end;

function XVCmykToColor(C, M, Y, K: Double): TXVColor;
begin
  C := EnsureRange(C, 0, 1); M := EnsureRange(M, 0, 1);
  Y := EnsureRange(Y, 0, 1); K := EnsureRange(K, 0, 1);
  Result := XVRGB(Round(255 * (1 - C) * (1 - K)), Round(255 * (1 - M) * (1 - K)), Round(255 * (1 - Y) * (1 - K)));
end;

function XVHexColor(C: TXVColor): string;
begin
  Result := '#' + IntToHex((C shr 16) and $FF, 2) + IntToHex((C shr 8) and $FF, 2) + IntToHex(C and $FF, 2);
end;

// ------------------------------ paints -------------------------------------

function XVNoPaint: TXVPaint;
begin
  Result.Kind := pkNone;
  Result.Color := 0;
  Result.Index := -1;
end;

function XVSolid(C: TXVColor): TXVPaint;
begin
  Result.Kind := pkSolid;
  Result.Color := C;
  Result.Index := -1;
end;

function XVGradientPaint(Index: Integer; AvgColor: TXVColor): TXVPaint;
begin
  Result.Kind := pkGradient;
  Result.Color := AvgColor;
  Result.Index := Index;
end;

function XVPatternPaint(Index: Integer; AvgColor: TXVColor): TXVPaint;
begin
  Result.Kind := pkPattern;
  Result.Color := AvgColor;
  Result.Index := Index;
end;

function XVNoStroke: TXVStroke;
begin
  Result := Default(TXVStroke);
  Result.Paint := XVNoPaint;
  Result.Width := 1;
  Result.MiterLimit := 4;
end;

function XVStroke(C: TXVColor; Width: Double): TXVStroke;
begin
  Result := XVNoStroke;
  Result.Paint := XVSolid(C);
  Result.Width := Width;
end;

function XVDefaultFont: TXVFont;
begin
  Result := Default(TXVFont);
  Result.Family := 'Arial';
  Result.Size := 16;
  Result.Weight := 400;
end;

// ------------------------------ geometry -----------------------------------

function XVPt(X, Y: Double): TXVPoint;
begin
  Result.X := X;
  Result.Y := Y;
end;

function XVRect(L, T, R, B: Double): TXVRect;
begin
  Result.Left := L; Result.Top := T; Result.Right := R; Result.Bottom := B;
end;

procedure XVUnionRect(var R: TXVRect; var HaveR: Boolean; const X: TXVRect);
begin
  if not HaveR then begin R := X; HaveR := True; Exit; end;
  if X.Left < R.Left then R.Left := X.Left;
  if X.Top < R.Top then R.Top := X.Top;
  if X.Right > R.Right then R.Right := X.Right;
  if X.Bottom > R.Bottom then R.Bottom := X.Bottom;
end;

function TXVRect.Width: Double;
begin
  Result := Right - Left;
end;

function TXVRect.Height: Double;
begin
  Result := Bottom - Top;
end;

function TXVRect.IsEmpty: Boolean;
begin
  Result := (Right <= Left) or (Bottom <= Top);
end;

function XVMul(const M1, M2: TXVMatrix): TXVMatrix;
begin
  Result.A := M1.A * M2.A + M1.C * M2.B;
  Result.B := M1.B * M2.A + M1.D * M2.B;
  Result.C := M1.A * M2.C + M1.C * M2.D;
  Result.D := M1.B * M2.C + M1.D * M2.D;
  Result.E := M1.A * M2.E + M1.C * M2.F + M1.E;
  Result.F := M1.B * M2.E + M1.D * M2.F + M1.F;
end;

class function TXVMatrix.Identity: TXVMatrix;
begin
  Result.A := 1; Result.B := 0; Result.C := 0; Result.D := 1; Result.E := 0; Result.F := 0;
end;

class function TXVMatrix.Make(AA, AB, AC, AD, AE, AF: Double): TXVMatrix;
begin
  Result.A := AA; Result.B := AB; Result.C := AC; Result.D := AD; Result.E := AE; Result.F := AF;
end;

class function TXVMatrix.Translate(X, Y: Double): TXVMatrix;
begin
  Result := Make(1, 0, 0, 1, X, Y);
end;

class function TXVMatrix.Scale(SX, SY: Double): TXVMatrix;
begin
  Result := Make(SX, 0, 0, SY, 0, 0);
end;

class function TXVMatrix.Rotate(Rad: Double): TXVMatrix;
var c, s: Double;
begin
  c := Cos(Rad); s := Sin(Rad);
  Result := Make(c, s, -s, c, 0, 0);
end;

class function TXVMatrix.SkewX(Rad: Double): TXVMatrix;
begin
  Result := Make(1, 0, Tan(Rad), 1, 0, 0);
end;

class function TXVMatrix.SkewY(Rad: Double): TXVMatrix;
begin
  Result := Make(1, Tan(Rad), 0, 1, 0, 0);
end;

function TXVMatrix.Apply(const P: TXVPoint): TXVPoint;
begin
  Result.X := A * P.X + C * P.Y + E;
  Result.Y := B * P.X + D * P.Y + F;
end;

function TXVMatrix.Apply(X, Y: Double): TXVPoint;
begin
  Result.X := A * X + C * Y + E;
  Result.Y := B * X + D * Y + F;
end;

procedure TXVMatrix.ApplyXY(var X, Y: Double);
var tx: Double;
begin
  tx := A * X + C * Y + E;
  Y := B * X + D * Y + F;
  X := tx;
end;

function TXVMatrix.ApplyVec(X, Y: Double): TXVPoint;
begin
  Result.X := A * X + C * Y;
  Result.Y := B * X + D * Y;
end;

function TXVMatrix.Det: Double;
begin
  Result := A * D - B * C;
end;

function TXVMatrix.Invert: TXVMatrix;
var dt: Double;
begin
  dt := Det;
  if Abs(dt) < 1e-300 then Exit(Identity);
  Result.A := D / dt;
  Result.B := -B / dt;
  Result.C := -C / dt;
  Result.D := A / dt;
  Result.E := (C * F - D * E) / dt;
  Result.F := (B * E - A * F) / dt;
end;

function TXVMatrix.IsIdentity: Boolean;
begin
  Result := (Abs(A - 1) < 1e-12) and (Abs(B) < 1e-12) and (Abs(C) < 1e-12) and (Abs(D - 1) < 1e-12) and
    (Abs(E) < 1e-12) and (Abs(F) < 1e-12);
end;

function TXVMatrix.ScaleFactor: Double;
begin
  Result := Sqrt(Abs(A * D - B * C));
end;

function TXVMatrix.RotationAngle: Double;
begin
  Result := ArcTan2(B, A);
end;

// ------------------------------ path ---------------------------------------

procedure TXVPath.Clear;
begin
  NCmd := 0; NPt := 0;
  FOpen := False;
  FStart.X := 0; FStart.Y := 0;
  FCur := FStart;
end;

procedure PathAddCmd(var P: TXVPath; C: TXVPathCmd);
begin
  if P.NCmd >= Length(P.Cmds) then SetLength(P.Cmds, Max(16, P.NCmd * 2));
  P.Cmds[P.NCmd] := C;
  Inc(P.NCmd);
end;

procedure PathAddPt(var P: TXVPath; X, Y: Double);
begin
  if P.NPt >= Length(P.Pts) then SetLength(P.Pts, Max(16, P.NPt * 2));
  P.Pts[P.NPt].X := X;
  P.Pts[P.NPt].Y := Y;
  Inc(P.NPt);
end;

procedure TXVPath.MoveTo(X, Y: Double);
begin
  // two moves in a row: the second replaces the first
  if (NCmd > 0) and (Cmds[NCmd - 1] = pcMoveTo) then
  begin
    Pts[NPt - 1].X := X; Pts[NPt - 1].Y := Y;
  end
  else
  begin
    PathAddCmd(Self, pcMoveTo);
    PathAddPt(Self, X, Y);
  end;
  FStart.X := X; FStart.Y := Y;
  FCur := FStart;
  FOpen := True;
end;

procedure TXVPath.LineTo(X, Y: Double);
begin
  if not FOpen then begin MoveTo(X, Y); Exit; end;
  if (NCmd > 0) and (Cmds[NCmd - 1] = pcClose) then MoveTo(FCur.X, FCur.Y);
  PathAddCmd(Self, pcLineTo);
  PathAddPt(Self, X, Y);
  FCur.X := X; FCur.Y := Y;
end;

procedure TXVPath.CubicTo(X1, Y1, X2, Y2, X, Y: Double);
begin
  if not FOpen then MoveTo(X1, Y1);
  if (NCmd > 0) and (Cmds[NCmd - 1] = pcClose) then MoveTo(FCur.X, FCur.Y);
  PathAddCmd(Self, pcCubicTo);
  PathAddPt(Self, X1, Y1);
  PathAddPt(Self, X2, Y2);
  PathAddPt(Self, X, Y);
  FCur.X := X; FCur.Y := Y;
end;

procedure TXVPath.QuadTo(X1, Y1, X, Y: Double);
var x0, y0: Double;
begin
  if not FOpen then MoveTo(X1, Y1);
  x0 := FCur.X; y0 := FCur.Y;
  CubicTo(x0 + 2 / 3 * (X1 - x0), y0 + 2 / 3 * (Y1 - y0), X + 2 / 3 * (X1 - X), Y + 2 / 3 * (Y1 - Y), X, Y);
end;

// rational quadratic (conic) of weight W as one cubic: exact for W = 1
procedure TXVPath.ConicTo(X1, Y1, X, Y, W: Double);
var x0, y0, k: Double;
begin
  if not FOpen then MoveTo(X1, Y1);
  if W <= 0 then begin LineTo(X, Y); Exit; end;
  x0 := FCur.X; y0 := FCur.Y;
  k := 4 * W / (3 * (1 + W));
  CubicTo(x0 + k * (X1 - x0), y0 + k * (Y1 - y0), X + k * (X1 - X), Y + k * (Y1 - Y), X, Y);
end;

procedure TXVPath.ArcCenter(CX, CY, RX, RY, RotRad, StartRad, SweepRad: Double; Lead: Integer);
var
  n, i: Integer;
  d, k, ta, tb, cr, sr: Double;

  procedure P(u, v: Double; out x, y: Double);
  var ex, ey: Double;
  begin
    ex := RX * u; ey := RY * v;
    x := CX + cr * ex - sr * ey;
    y := CY + sr * ex + cr * ey;
  end;

var x0, y0, x1, y1, x2, y2, x3, y3: Double;
begin
  cr := Cos(RotRad); sr := Sin(RotRad);
  P(Cos(StartRad), Sin(StartRad), x0, y0);
  case Lead of
    1: MoveTo(x0, y0);
    2: LineTo(x0, y0);
  else
    if not FOpen then MoveTo(x0, y0);
  end;
  if Abs(SweepRad) < 1e-12 then Exit;
  n := Max(1, Ceil(Abs(SweepRad) / (Pi / 2) - 1e-9));
  if n > 64 then n := 64;
  d := SweepRad / n;
  k := 4 / 3 * Tan(d / 4);
  for i := 0 to n - 1 do
  begin
    ta := StartRad + i * d; tb := ta + d;
    P(Cos(ta) - k * Sin(ta), Sin(ta) + k * Cos(ta), x1, y1);
    P(Cos(tb) + k * Sin(tb), Sin(tb) - k * Cos(tb), x2, y2);
    P(Cos(tb), Sin(tb), x3, y3);
    CubicTo(x1, y1, x2, y2, x3, y3);
  end;
end;

function VecAngle(UX, UY, VX, VY: Double): Double;
var dp, lp, a: Double;
begin
  lp := Hypot(UX, UY) * Hypot(VX, VY);
  if lp < 1e-300 then Exit(0);
  dp := UX * VX + UY * VY;
  a := EnsureRange(dp / lp, -1, 1);
  Result := ArcCos(a);
  if (UX * VY - UY * VX) < 0 then Result := -Result;
end;

procedure TXVPath.ArcTo(RX, RY, XRotDeg: Double; LargeArc, Sweep: Boolean; X, Y: Double);
var
  x1, y1, phi, cp, sp, dx2, dy2, x1p, y1p, lambda, num, den, fac, cxp, cyp, cx, cy: Double;
  ux, uy, vx, vy, th1, dth: Double;
begin
  if not FOpen then MoveTo(X, Y);
  x1 := FCur.X; y1 := FCur.Y;
  if (Abs(x1 - X) < 1e-12) and (Abs(y1 - Y) < 1e-12) then Exit;
  RX := Abs(RX); RY := Abs(RY);
  if (RX < 1e-12) or (RY < 1e-12) then begin LineTo(X, Y); Exit; end;
  phi := DegToRad(XRotDeg);
  cp := Cos(phi); sp := Sin(phi);
  dx2 := (x1 - X) / 2; dy2 := (y1 - Y) / 2;
  x1p := cp * dx2 + sp * dy2;
  y1p := -sp * dx2 + cp * dy2;
  lambda := Sqr(x1p) / Sqr(RX) + Sqr(y1p) / Sqr(RY);
  if lambda > 1 then
  begin
    lambda := Sqrt(lambda);
    RX := RX * lambda; RY := RY * lambda;
  end;
  num := Sqr(RX) * Sqr(RY) - Sqr(RX) * Sqr(y1p) - Sqr(RY) * Sqr(x1p);
  den := Sqr(RX) * Sqr(y1p) + Sqr(RY) * Sqr(x1p);
  if Abs(den) < 1e-300 then fac := 0
  else
  begin
    fac := num / den;
    if fac < 0 then fac := 0;
    fac := Sqrt(fac);
  end;
  if LargeArc = Sweep then fac := -fac;
  cxp := fac * (RX * y1p / RY);
  cyp := fac * (-RY * x1p / RX);
  cx := cp * cxp - sp * cyp + (x1 + X) / 2;
  cy := sp * cxp + cp * cyp + (y1 + Y) / 2;
  ux := (x1p - cxp) / RX; uy := (y1p - cyp) / RY;
  vx := (-x1p - cxp) / RX; vy := (-y1p - cyp) / RY;
  th1 := VecAngle(1, 0, ux, uy);
  dth := VecAngle(ux, uy, vx, vy);
  if (not Sweep) and (dth > 0) then dth := dth - 2 * Pi
  else if Sweep and (dth < 0) then dth := dth + 2 * Pi;
  ArcCenter(cx, cy, RX, RY, phi, th1, dth, 0);
  // land exactly on the end point
  if NPt > 0 then begin Pts[NPt - 1].X := X; Pts[NPt - 1].Y := Y; end;
  FCur.X := X; FCur.Y := Y;
end;

procedure TXVPath.Close;
begin
  if not FOpen then Exit;
  if (NCmd > 0) and (Cmds[NCmd - 1] in [pcClose, pcMoveTo]) then
  begin
    if Cmds[NCmd - 1] = pcMoveTo then begin Dec(NCmd); Dec(NPt); FOpen := NCmd > 0; end;
    Exit;
  end;
  PathAddCmd(Self, pcClose);
  FCur := FStart;
end;

procedure TXVPath.AddRect(X, Y, W, H: Double);
begin
  MoveTo(X, Y);
  LineTo(X + W, Y);
  LineTo(X + W, Y + H);
  LineTo(X, Y + H);
  Close;
end;

procedure TXVPath.AddRoundRect(X, Y, W, H, RX, RY: Double);
begin
  if W < 0 then begin X := X + W; W := -W; end;
  if H < 0 then begin Y := Y + H; H := -H; end;
  RX := Min(Abs(RX), W / 2); RY := Min(Abs(RY), H / 2);
  if (RX <= 0) or (RY <= 0) then begin AddRect(X, Y, W, H); Exit; end;
  MoveTo(X + RX, Y);
  LineTo(X + W - RX, Y);
  ArcCenter(X + W - RX, Y + RY, RX, RY, 0, -Pi / 2, Pi / 2, 0);
  LineTo(X + W, Y + H - RY);
  ArcCenter(X + W - RX, Y + H - RY, RX, RY, 0, 0, Pi / 2, 0);
  LineTo(X + RX, Y + H);
  ArcCenter(X + RX, Y + H - RY, RX, RY, 0, Pi / 2, Pi / 2, 0);
  LineTo(X, Y + RY);
  ArcCenter(X + RX, Y + RY, RX, RY, 0, Pi, Pi / 2, 0);
  Close;
end;

procedure TXVPath.AddEllipse(CX, CY, RX, RY: Double);
begin
  ArcCenter(CX, CY, RX, RY, 0, 0, 2 * Pi, 1);
  Close;
end;

procedure TXVPath.AddPolygon(const P: array of TXVPoint; Closed: Boolean);
var i: Integer;
begin
  if Length(P) = 0 then Exit;
  MoveTo(P[0].X, P[0].Y);
  for i := 1 to High(P) do LineTo(P[i].X, P[i].Y);
  if Closed then Close;
end;

procedure TXVPath.Append(const P: TXVPath);
var i, k: Integer;
begin
  k := 0;
  for i := 0 to P.NCmd - 1 do
    case P.Cmds[i] of
      pcMoveTo: begin MoveTo(P.Pts[k].X, P.Pts[k].Y); Inc(k); end;
      pcLineTo: begin LineTo(P.Pts[k].X, P.Pts[k].Y); Inc(k); end;
      pcCubicTo:
        begin
          CubicTo(P.Pts[k].X, P.Pts[k].Y, P.Pts[k + 1].X, P.Pts[k + 1].Y, P.Pts[k + 2].X, P.Pts[k + 2].Y);
          Inc(k, 3);
        end;
      pcClose: Close;
    end;
end;

procedure TXVPath.Transform(const M: TXVMatrix);
var i: Integer;
begin
  for i := 0 to NPt - 1 do Pts[i] := M.Apply(Pts[i]);
  FStart := M.Apply(FStart);
  FCur := M.Apply(FCur);
end;

function TXVPath.Bounds(out R: TXVRect): Boolean;
var i: Integer;
begin
  Result := NPt > 0;
  if not Result then begin R := XVRect(0, 0, 0, 0); Exit; end;
  R := XVRect(Pts[0].X, Pts[0].Y, Pts[0].X, Pts[0].Y);
  for i := 1 to NPt - 1 do
  begin
    if Pts[i].X < R.Left then R.Left := Pts[i].X;
    if Pts[i].X > R.Right then R.Right := Pts[i].X;
    if Pts[i].Y < R.Top then R.Top := Pts[i].Y;
    if Pts[i].Y > R.Bottom then R.Bottom := Pts[i].Y;
  end;
end;

function TXVPath.IsEmpty: Boolean;
var i: Integer;
begin
  for i := 0 to NCmd - 1 do
    if Cmds[i] in [pcLineTo, pcCubicTo] then Exit(False);
  Result := True;
end;

function TXVPath.HasCurrent: Boolean;
begin
  Result := FOpen;
end;

function TXVPath.CurrentPoint: TXVPoint;
begin
  Result := FCur;
end;

function TXVPath.StartPoint: TXVPoint;
begin
  Result := FStart;
end;

procedure TXVPath.Compact;
begin
  // a trailing move draws nothing
  while (NCmd > 0) and (Cmds[NCmd - 1] = pcMoveTo) do
  begin
    Dec(NCmd); Dec(NPt);
  end;
  SetLength(Cmds, NCmd);
  SetLength(Pts, NPt);
end;

function TXVPath.Copy: TXVPath;
begin
  Result := Self;
  Result.Cmds := System.Copy(Cmds, 0, NCmd);
  Result.Pts := System.Copy(Pts, 0, NPt);
end;

// ------------------------------ images -------------------------------------

function XVNewImage(W, H: Integer; Fill: Cardinal): TXVImage;
var i: Integer;
begin
  Result.W := Max(W, 0); Result.H := Max(H, 0);
  SetLength(Result.Px, Result.W * Result.H);
  if Fill <> 0 then
    for i := 0 to High(Result.Px) do Result.Px[i] := Fill
  else if Length(Result.Px) > 0 then
    FillChar(Result.Px[0], Length(Result.Px) * 4, 0);
end;

function XVImageAverage(const Img: TXVImage): TXVColor;
var
  i, n, stp: Integer;
  r, g, b, a: Int64;
  c: Cardinal;
begin
  if Length(Img.Px) = 0 then Exit(XV_BLACK);
  r := 0; g := 0; b := 0; a := 0; n := 0;
  stp := Max(1, Length(Img.Px) div 4096);
  i := 0;
  while i < Length(Img.Px) do
  begin
    c := Img.Px[i];
    Inc(a, c shr 24);
    Inc(r, ((c shr 16) and $FF) * (c shr 24));
    Inc(g, ((c shr 8) and $FF) * (c shr 24));
    Inc(b, (c and $FF) * (c shr 24));
    Inc(n);
    Inc(i, stp);
  end;
  if a = 0 then Exit(XV_TRANSPARENT);
  Result := XVRGBA(r div a, g div a, b div a, a div n);
end;

// ------------------------------ text helpers -------------------------------

function XVUtf8OfCode(CP: Cardinal): string;
begin
  if CP < $80 then Result := Chr(CP)
  else if CP < $800 then Result := Chr($C0 or (CP shr 6)) + Chr($80 or (CP and $3F))
  else if CP < $10000 then
    Result := Chr($E0 or (CP shr 12)) + Chr($80 or ((CP shr 6) and $3F)) + Chr($80 or (CP and $3F))
  else
    Result := Chr($F0 or (CP shr 18)) + Chr($80 or ((CP shr 12) and $3F)) +
      Chr($80 or ((CP shr 6) and $3F)) + Chr($80 or (CP and $3F));
end;

function XVUtf16ToUtf8(const D: TBytes; Ofs, Len: Integer): string;
var i, c, c2: Integer;
begin
  Result := '';
  i := Ofs;
  while (i + 1 < Ofs + Len) and (i + 1 < Length(D)) do
  begin
    c := D[i] or (D[i + 1] shl 8);
    Inc(i, 2);
    if (c >= $D800) and (c < $DC00) and (i + 1 < Length(D)) then
    begin
      c2 := D[i] or (D[i + 1] shl 8);
      if (c2 >= $DC00) and (c2 < $E000) then
      begin
        Inc(i, 2);
        c := $10000 + ((c - $D800) shl 10) + (c2 - $DC00);
      end;
    end;
    if c = 0 then Continue;
    Result := Result + XVUtf8OfCode(c);
  end;
end;

function XVCharsetCodePage(CharSet: Integer): Integer;
begin
  case CharSet of
    $00, $01: Result := 1252;
    $80: Result := 932;
    $81: Result := 949;
    $86: Result := 936;
    $88: Result := 950;
    $A1: Result := 1253;
    $A2: Result := 1254;
    $A3: Result := 1258;
    $B1: Result := 1255;
    $B2: Result := 1256;
    $BA: Result := 1257;
    $CC: Result := 1251;
    $DE: Result := 874;
    $EE: Result := 1250;
    $02: Result := 0;              // symbol: bytes as they are
    $4D: Result := 10000;          // Mac
  else
    Result := 1252;
  end;
end;

const
  // Windows-1250 / 1251 / 1252 upper halves, used when the RTL has no converter
  CP1252_HI: array[$80..$9F] of Word = (
    $20AC, $0081, $201A, $0192, $201E, $2026, $2020, $2021, $02C6, $2030, $0160, $2039, $0152, $008D, $017D, $008F,
    $0090, $2018, $2019, $201C, $201D, $2022, $2013, $2014, $02DC, $2122, $0161, $203A, $0153, $009D, $017E, $0178);
  CP1250_HI: array[$80..$FF] of Word = (
    $20AC, $0081, $201A, $0083, $201E, $2026, $2020, $2021, $0088, $2030, $0160, $2039, $015A, $0164, $017D, $0179,
    $0090, $2018, $2019, $201C, $201D, $2022, $2013, $2014, $0098, $2122, $0161, $203A, $015B, $0165, $017E, $017A,
    $00A0, $02C7, $02D8, $0141, $00A4, $0104, $00A6, $00A7, $00A8, $00A9, $015E, $00AB, $00AC, $00AD, $00AE, $017B,
    $00B0, $00B1, $02DB, $0142, $00B4, $00B5, $00B6, $00B7, $00B8, $0105, $015F, $00BB, $013D, $02DD, $013E, $017C,
    $0154, $00C1, $00C2, $0102, $00C4, $0139, $0106, $00C7, $010C, $00C9, $0118, $00CB, $011A, $00CD, $00CE, $010E,
    $0110, $0143, $0147, $00D3, $00D4, $0150, $00D6, $00D7, $0158, $016E, $00DA, $0170, $00DC, $00DD, $0162, $00DF,
    $0155, $00E1, $00E2, $0103, $00E4, $013A, $0107, $00E7, $010D, $00E9, $0119, $00EB, $011B, $00ED, $00EE, $010F,
    $0111, $0144, $0148, $00F3, $00F4, $0151, $00F6, $00F7, $0159, $016F, $00FA, $0171, $00FC, $00FD, $0163, $02D9);
  CP1251_HI: array[$80..$BF] of Word = (
    $0402, $0403, $201A, $0453, $201E, $2026, $2020, $2021, $20AC, $2030, $0409, $2039, $040A, $040C, $040B, $040F,
    $0452, $2018, $2019, $201C, $201D, $2022, $2013, $2014, $0098, $2122, $0459, $203A, $045A, $045C, $045B, $045F,
    $00A0, $040E, $045E, $0408, $00A4, $0490, $00A6, $00A7, $0401, $00A9, $0404, $00AB, $00AC, $00AD, $00AE, $0407,
    $00B0, $00B1, $0406, $0456, $0491, $00B5, $00B6, $00B7, $0451, $2116, $0454, $00BB, $0458, $0405, $0455, $0457);

function SingleByteToUnicode(b: Byte; CodePage: Integer; out u: Cardinal): Boolean;
begin
  Result := True;
  if b < $80 then begin u := b; Exit; end;
  case CodePage of
    1252, 28591:
      if (b <= $9F) and (CodePage = 1252) then u := CP1252_HI[b] else u := b;
    1250: u := CP1250_HI[b];
    1251: if b < $C0 then u := CP1251_HI[b] else u := $0410 + (b - $C0);
    0: u := b;
  else
    Result := False;
  end;
end;

function XVCodePageToUtf8(const D: TBytes; Ofs, Len, CodePage: Integer): string;
var
  i: Integer;
  u: Cardinal;
  sub: TBytes;
  enc: TEncoding;
  simple: Boolean;
begin
  Result := '';
  if Ofs + Len > Length(D) then Len := Length(D) - Ofs;
  if Len <= 0 then Exit;
  simple := (CodePage = 0) or (CodePage = 1250) or (CodePage = 1251) or (CodePage = 1252) or (CodePage = 28591);
  if simple then
  begin
    for i := Ofs to Ofs + Len - 1 do
    begin
      SingleByteToUnicode(D[i], CodePage, u);
      Result := Result + XVUtf8OfCode(u);
    end;
    Exit;
  end;
  if CodePage = 65001 then
  begin
    SetLength(Result, Len);
    Move(D[Ofs], Result[1], Len);
    Exit;
  end;
  SetLength(sub, Len);
  Move(D[Ofs], sub[0], Len);
  enc := nil;
  try
    try
      enc := TEncoding.GetEncoding(CodePage);
      Result := UTF8Encode(enc.GetString(sub));
    except
      Result := '';
      for i := 0 to Len - 1 do
      begin
        SingleByteToUnicode(sub[i], 1252, u);
        Result := Result + XVUtf8OfCode(u);
      end;
    end;
  finally
    enc.Free;
  end;
end;

function XVUtf8Chars(const S: string): TStringArray;
var i, n, st: Integer;
begin
  Result := nil;
  n := 0;
  i := 1;
  while i <= Length(S) do
  begin
    st := i;
    Inc(i);
    while (i <= Length(S)) and ((Ord(S[i]) and $C0) = $80) do Inc(i);
    SetLength(Result, n + 1);
    Result[n] := System.Copy(S, st, i - st);
    Inc(n);
  end;
end;

const
  HELV: array[32..126] of Word = (
    278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
    1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
    333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
    556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584);

function XVEstimateTextWidth(const Font: TXVFont; const S: string): Double;
var
  ch: TStringArray;
  i: Integer;
  w: Double;
  c: Integer;
begin
  ch := XVUtf8Chars(S);
  w := 0;
  for i := 0 to High(ch) do
  begin
    if Length(ch[i]) = 1 then c := Ord(ch[i][1]) else c := 0;
    if (c >= 32) and (c <= 126) then w := w + HELV[c] else w := w + 556;
  end;
  if Font.Weight >= 600 then w := w * 1.06;
  if (Pos('courier', LowerCase(Font.Family)) > 0) or (Pos('mono', LowerCase(Font.Family)) > 0) then
    w := Length(ch) * 600;
  Result := w / 1000 * Font.Size;
end;

// ------------------------------ numbers ------------------------------------

var
  GFS: TFormatSettings;

function XVFmt(V: Double; Decimals: Integer): string;
var i: Integer;
begin
  if IsNan(V) or IsInfinite(V) then Exit('0');
  if Abs(V) < 0.5 * Power(10, -Decimals) then Exit('0');
  Result := FloatToStrF(V, ffFixed, 18, Decimals, GFS);
  if Pos('.', Result) > 0 then
  begin
    i := Length(Result);
    while Result[i] = '0' do Dec(i);
    if Result[i] = '.' then Dec(i);
    SetLength(Result, i);
  end;
  if Result = '-0' then Result := '0';
end;

function XVStrToFloat(const S: string; Def: Double): Double;
var
  t: string;
  code: Integer;
begin
  t := Trim(S);
  if t = '' then Exit(Def);
  Val(t, Result, code);
  if code <> 0 then
  begin
    // a number followed by something else ("12px"): take the number part
    if code > 1 then
    begin
      Val(System.Copy(t, 1, code - 1), Result, code);
      if code = 0 then Exit;
    end;
    Result := Def;
  end;
  if IsNan(Result) or IsInfinite(Result) then Result := Def;
end;

function XVReadFileBytes(const FileName: string): TBytes;
var fs: TFileStream;
begin
  fs := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(Result[0], fs.Size);
  finally
    fs.Free;
  end;
end;

function XVIsGzip(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) > 18) and (Data[0] = $1F) and (Data[1] = $8B) and (Data[2] = 8);
end;

// gzip member: header (optional extra field, name, comment, header CRC),
// raw deflate data, CRC and size
function XVGunzip(const Data: TBytes): TBytes;
var
  p, fl: Integer;
begin
  Result := nil;
  if not XVIsGzip(Data) then Exit;
  fl := Data[3];
  p := 10;
  if (fl and 4) <> 0 then p := p + 2 + (Data[p] or (Data[p + 1] shl 8));
  if (fl and 8) <> 0 then
  begin
    while (p < Length(Data)) and (Data[p] <> 0) do Inc(p);
    Inc(p);
  end;
  if (fl and 16) <> 0 then
  begin
    while (p < Length(Data)) and (Data[p] <> 0) do Inc(p);
    Inc(p);
  end;
  if (fl and 2) <> 0 then Inc(p, 2);
  if p >= Length(Data) then Exit;
  Result := InflateRaw(@Data[p], Length(Data) - p);
end;

function GzInnerName(const FileName: string): string;
var e: string;
begin
  e := LowerCase(ExtractFileExt(FileName));
  if e = '.svgz' then Result := ChangeFileExt(FileName, '.svg')
  else if e = '.emz' then Result := ChangeFileExt(FileName, '.emf')
  else if e = '.wmz' then Result := ChangeFileExt(FileName, '.wmf')
  else if e = '.gz' then Result := ChangeFileExt(FileName, '')
  else Result := FileName;
end;

// ------------------------------ document -----------------------------------

constructor TXVDocument.Create;
begin
  inherited Create;
  Clear;
end;

destructor TXVDocument.Destroy;
begin
  Clear;
  inherited Destroy;
end;

procedure TXVDocument.Clear;
begin
  Elements := nil;
  FCount := 0;
  Gradients := nil;
  Patterns := nil;
  Images := nil;
  Clips := nil;
  Width := 0; Height := 0;
  ViewBox := XVRect(0, 0, 0, 0);
  Background := 0;
  SourceFormat := '';
  Title := '';
  PageCount := 1;
end;

function TXVDocument.GetElement(Index: Integer): PXVElement;
begin
  Result := @Elements[Index];
end;

function TXVDocument.NewElement(AKind: TXVElementKind): Integer;
begin
  if FCount >= Length(Elements) then SetLength(Elements, Max(64, FCount * 2));
  Result := FCount;
  Elements[Result] := Default(TXVElement);
  Elements[Result].Kind := AKind;
  Elements[Result].Opacity := 1;
  Elements[Result].Clip := -1;
  Elements[Result].Image := -1;
  Elements[Result].Fill := XVNoPaint;
  Elements[Result].Stroke := XVNoStroke;
  Elements[Result].Matrix := TXVMatrix.Identity;
  Inc(FCount);
end;

function TXVDocument.AddPath(const P: TXVPath; const AFill: TXVPaint; const AStroke: TXVStroke;
  ARule: TXVFillRule; AOpacity: Double): Integer;
begin
  Result := -1;
  if (P.NCmd = 0) or ((AFill.Kind = pkNone) and (AStroke.Paint.Kind = pkNone)) then Exit;
  Result := NewElement(ekPath);
  with Elements[Result] do
  begin
    Path := P.Copy;
    Path.Compact;
    Fill := AFill;
    Stroke := AStroke;
    FillRule := ARule;
    Opacity := AOpacity;
  end;
end;

function TXVDocument.AddText(const AText: string; const AFont: TXVFont; const M: TXVMatrix;
  const AFill: TXVPaint; AAnchor: TXVTextAnchor): Integer;
begin
  Result := NewElement(ekText);
  with Elements[Result] do
  begin
    Text := AText;
    Font := AFont;
    if Font.Weight = 0 then Font.Weight := 400;
    if Font.Family = '' then Font.Family := 'Arial';
    Matrix := M;
    Fill := AFill;
    Anchor := AAnchor;
  end;
end;

function TXVDocument.AddImage(AImage: Integer; const M: TXVMatrix; AOpacity: Double): Integer;
begin
  Result := NewElement(ekImage);
  Elements[Result].Image := AImage;
  Elements[Result].Matrix := M;
  Elements[Result].Opacity := AOpacity;
end;

function TXVDocument.BeginGroup(AClip: Integer; AOpacity: Double): Integer;
begin
  Result := NewElement(ekGroup);
  Elements[Result].Clip := AClip;
  Elements[Result].Opacity := AOpacity;
end;

procedure TXVDocument.EndGroup;
begin
  NewElement(ekGroupEnd);
end;

procedure TXVDocument.SetElements(const AElements: array of TXVElement);
var i: Integer;
begin
  SetLength(Elements, Length(AElements));
  for i := 0 to High(AElements) do Elements[i] := AElements[i];
  FCount := Length(AElements);
end;

procedure TXVDocument.Truncate(ACount: Integer);
begin
  if (ACount >= 0) and (ACount < FCount) then FCount := ACount;
end;

procedure TXVDocument.AppendDocument(Other: TXVDocument; const M: TXVMatrix);
var
  g0, p0, i0, c0, i, k, n: Integer;
  s: Double;
  e: TXVElement;

  procedure Remap(var P: TXVPaint);
  begin
    if P.Kind = pkGradient then Inc(P.Index, g0)
    else if P.Kind = pkPattern then Inc(P.Index, p0);
  end;

begin
  g0 := Length(Gradients); p0 := Length(Patterns); i0 := Length(Images); c0 := Length(Clips);
  SetLength(Images, i0 + Length(Other.Images));
  for i := 0 to High(Other.Images) do Images[i0 + i] := Other.Images[i];
  SetLength(Gradients, g0 + Length(Other.Gradients));
  for i := 0 to High(Other.Gradients) do
  begin
    Gradients[g0 + i] := Other.Gradients[i];
    Gradients[g0 + i].Stops := System.Copy(Other.Gradients[i].Stops);
    Gradients[g0 + i].Matrix := XVMul(M, Other.Gradients[i].Matrix);
  end;
  SetLength(Patterns, p0 + Length(Other.Patterns));
  for i := 0 to High(Other.Patterns) do
  begin
    Patterns[p0 + i] := Other.Patterns[i];
    Patterns[p0 + i].Image := Other.Patterns[i].Image + i0;
    Patterns[p0 + i].Matrix := XVMul(M, Other.Patterns[i].Matrix);
  end;
  SetLength(Clips, c0 + Length(Other.Clips));
  for i := 0 to High(Other.Clips) do
  begin
    Clips[c0 + i].Path := Other.Clips[i].Path.Copy;
    Clips[c0 + i].Path.Transform(M);
    Clips[c0 + i].Rule := Other.Clips[i].Rule;
  end;
  s := M.ScaleFactor;
  for i := 0 to Other.Count - 1 do
  begin
    e := Other.Elements[i];
    n := NewElement(e.Kind);
    e.Path := e.Path.Copy;
    e.Path.Transform(M);
    e.Stroke.Width := e.Stroke.Width * s;
    e.Stroke.Dashes := System.Copy(e.Stroke.Dashes);
    for k := 0 to High(e.Stroke.Dashes) do e.Stroke.Dashes[k] := e.Stroke.Dashes[k] * s;
    e.Stroke.DashOffset := e.Stroke.DashOffset * s;
    Remap(e.Fill);
    Remap(e.Stroke.Paint);
    if e.Clip >= 0 then Inc(e.Clip, c0);
    if e.Image >= 0 then Inc(e.Image, i0);
    if e.Kind in [ekText, ekImage] then
    begin
      if e.Continued then
      begin
        // the shift of a continued run: a vector
        e.Matrix := XVMul(M, e.Matrix);
        e.Matrix.E := M.ApplyVec(Other.Elements[i].Matrix.E, Other.Elements[i].Matrix.F).X;
        e.Matrix.F := M.ApplyVec(Other.Elements[i].Matrix.E, Other.Elements[i].Matrix.F).Y;
      end
      else e.Matrix := XVMul(M, e.Matrix);
    end;
    Elements[n] := e;
  end;
end;

procedure TXVDocument.AppendDocumentInto(Other: TXVDocument; X, Y, W, H: Double; const M: TXVMatrix);
var
  vb: TXVRect;
  t: TXVMatrix;
  clip: TXVPath;
begin
  vb := Other.ViewBox;
  if vb.IsEmpty then vb := XVRect(0, 0, Max(Other.Width, 1), Max(Other.Height, 1));
  t := XVMul(M, TXVMatrix.Make(W / vb.Width, 0, 0, H / vb.Height, X - vb.Left * W / vb.Width, Y - vb.Top * H / vb.Height));
  clip := Default(TXVPath);
  clip.Clear;
  clip.AddRect(X, Y, W, H);
  clip.Transform(M);
  BeginGroup(AddClip(clip, frNonZero), 1);
  if (Other.Background shr 24) <> 0 then
  begin
    clip.Clear;
    clip.AddRect(X, Y, W, H);
    clip.Transform(M);
    AddPath(clip, XVSolid(Other.Background), XVNoStroke);
  end;
  AppendDocument(Other, t);
  EndGroup;
end;

function TXVDocument.AddGradient(const G: TXVGradient): Integer;
begin
  Result := Length(Gradients);
  SetLength(Gradients, Result + 1);
  Gradients[Result] := G;
end;

function TXVDocument.AddPattern(AImage: Integer; const M: TXVMatrix; ADeviceTile: Boolean): Integer;
begin
  Result := Length(Patterns);
  SetLength(Patterns, Result + 1);
  Patterns[Result].Image := AImage;
  Patterns[Result].Matrix := M;
  Patterns[Result].DeviceTile := ADeviceTile;
end;

function TXVDocument.AddImageData(const Img: TXVImage): Integer;
begin
  Result := Length(Images);
  SetLength(Images, Result + 1);
  Images[Result] := Img;
end;

function TXVDocument.AddClip(const P: TXVPath; ARule: TXVFillRule): Integer;
begin
  Result := Length(Clips);
  SetLength(Clips, Result + 1);
  Clips[Result].Path := P.Copy;
  Clips[Result].Path.Compact;
  Clips[Result].Rule := ARule;
end;

function TXVDocument.ContentBounds(out R: TXVRect): Boolean;
var
  i: Integer;
  b: TXVRect;
  hw, sz: Double;
  p: array[0..3] of TXVPoint;
  k: Integer;
begin
  Result := False;
  R := XVRect(0, 0, 0, 0);
  for i := 0 to FCount - 1 do
    with Elements[i] do
      case Kind of
        ekPath:
          if Path.Bounds(b) then
          begin
            if Stroke.Paint.Kind <> pkNone then
            begin
              hw := Stroke.Width / 2;
              b.Left := b.Left - hw; b.Top := b.Top - hw; b.Right := b.Right + hw; b.Bottom := b.Bottom + hw;
            end;
            XVUnionRect(R, Result, b);
          end;
        ekText:
          begin
            sz := Font.Size;
            hw := sz * 0.6 * Length(XVUtf8Chars(Text));
            p[0] := Matrix.Apply(0, -sz); p[1] := Matrix.Apply(hw, -sz);
            p[2] := Matrix.Apply(0, sz * 0.25); p[3] := Matrix.Apply(hw, sz * 0.25);
            b := XVRect(p[0].X, p[0].Y, p[0].X, p[0].Y);
            for k := 1 to 3 do
            begin
              b.Left := Min(b.Left, p[k].X); b.Right := Max(b.Right, p[k].X);
              b.Top := Min(b.Top, p[k].Y); b.Bottom := Max(b.Bottom, p[k].Y);
            end;
            XVUnionRect(R, Result, b);
          end;
        ekImage:
          if (Image >= 0) and (Image < Length(Images)) then
          begin
            p[0] := Matrix.Apply(0, 0); p[1] := Matrix.Apply(Images[Image].W, 0);
            p[2] := Matrix.Apply(0, Images[Image].H); p[3] := Matrix.Apply(Images[Image].W, Images[Image].H);
            b := XVRect(p[0].X, p[0].Y, p[0].X, p[0].Y);
            for k := 1 to 3 do
            begin
              b.Left := Min(b.Left, p[k].X); b.Right := Max(b.Right, p[k].X);
              b.Top := Min(b.Top, p[k].Y); b.Bottom := Max(b.Bottom, p[k].Y);
            end;
            XVUnionRect(R, Result, b);
          end;
      end;
end;

procedure TXVDocument.SetPageSize(AWidth, AHeight: Double);
begin
  Width := AWidth;
  Height := AHeight;
  ViewBox := XVRect(0, 0, AWidth, AHeight);
end;

procedure TXVDocument.FitToContent(Margin: Double);
var r: TXVRect;
begin
  if not ContentBounds(r) then
  begin
    if Width <= 0 then SetPageSize(100, 100);
    Exit;
  end;
  r.Left := r.Left - Margin; r.Top := r.Top - Margin;
  r.Right := r.Right + Margin; r.Bottom := r.Bottom + Margin;
  if r.Width < 1e-9 then r.Right := r.Left + 1;
  if r.Height < 1e-9 then r.Bottom := r.Top + 1;
  ViewBox := r;
  Width := r.Width;
  Height := r.Height;
end;

procedure TXVDocument.Transform(const M: TXVMatrix);
var
  i, k: Integer;
  s: Double;
begin
  s := M.ScaleFactor;
  for i := 0 to FCount - 1 do
    with Elements[i] do
    begin
      Path.Transform(M);
      Stroke.Width := Stroke.Width * s;
      for k := 0 to High(Stroke.Dashes) do Stroke.Dashes[k] := Stroke.Dashes[k] * s;
      Stroke.DashOffset := Stroke.DashOffset * s;
      if Kind in [ekText, ekImage] then Matrix := XVMul(M, Matrix);
    end;
  for i := 0 to High(Clips) do Clips[i].Path.Transform(M);
  for i := 0 to High(Gradients) do Gradients[i].Matrix := XVMul(M, Gradients[i].Matrix);
  for i := 0 to High(Patterns) do Patterns[i].Matrix := XVMul(M, Patterns[i].Matrix);
end;

function ExtOf(const FileName: string): string;
begin
  Result := LowerCase(ExtractFileExt(FileName));
  if (Result <> '') and (Result[1] = '.') then Delete(Result, 1, 1);
end;

function ExtInList(const Ext, List: string): Boolean;
begin
  Result := (Ext <> '') and (Pos(';' + Ext + ';', ';' + LowerCase(List) + ';') > 0);
end;

function XVDetectFormat(const Data: TBytes; const FileNameHint: string): string;
var
  i: Integer;
  ext: string;
begin
  for i := 0 to High(GReaders) do
    if Assigned(GReaders[i].Detect) and GReaders[i].Detect(Data) then Exit(GReaders[i].Name);
  ext := ExtOf(FileNameHint);
  for i := 0 to High(GReaders) do
    if ExtInList(ext, GReaders[i].Exts) then Exit(GReaders[i].Name);
  Result := '';
end;

procedure TXVDocument.LoadFromBytes(const Data: TBytes; const FileNameHint: string);
var
  fmt: string;
  i, keep: Integer;
begin
  keep := LoadPage;
  Clear;
  LoadPage := keep;
  // gzip wrapped files (svgz, emz, wmz): the inflated content is read
  if XVIsGzip(Data) then
  begin
    LoadFromBytes(XVGunzip(Data), GzInnerName(FileNameHint));
    Exit;
  end;
  fmt := XVDetectFormat(Data, FileNameHint);
  if fmt = '' then raise EXVError.Create('XelVectors: unknown file format');
  for i := 0 to High(GReaders) do
    if GReaders[i].Name = fmt then
    begin
      SourceFormat := fmt;
      SourceFile := FileNameHint;
      GReaders[i].Read(Self, Data);
      SourceFormat := fmt;
      if FCount < Length(Elements) then SetLength(Elements, FCount);
      if (Width <= 0) or (Height <= 0) or ViewBox.IsEmpty then FitToContent;
      Exit;
    end;
end;

procedure TXVDocument.LoadFromStream(Stream: TStream; const FileNameHint: string);
var d: TBytes;
begin
  SetLength(d, Stream.Size - Stream.Position);
  if Length(d) > 0 then Stream.ReadBuffer(d[0], Length(d));
  LoadFromBytes(d, FileNameHint);
end;

procedure TXVDocument.LoadFromFile(const FileName: string);
begin
  LoadFromBytes(XVReadFileBytes(FileName), FileName);
end;

procedure TXVDocument.SaveToStream(Stream: TStream; const Format: string);
var
  i: Integer;
  f: string;
begin
  f := LowerCase(Format);
  if (f <> '') and (f[1] = '.') then Delete(f, 1, 1);
  for i := 0 to High(GWriters) do
    if (LowerCase(GWriters[i].Name) = f) or ExtInList(f, GWriters[i].Exts) then
    begin
      GWriters[i].Write(Self, Stream);
      Exit;
    end;
  raise EXVError.Create('XelVectors: no writer for "' + Format + '"');
end;

procedure TXVDocument.SaveToFile(const FileName: string);
var fs: TFileStream;
begin
  fs := TFileStream.Create(FileName, fmCreate);
  try
    SaveToStream(fs, ExtOf(FileName));
  finally
    fs.Free;
  end;
end;

// ------------------------------ registry -----------------------------------

procedure XVRegisterReader(const AName, AExtensions: string; ADetect: TXVDetectFunc; ARead: TXVReadFunc);
var n: Integer;
begin
  n := Length(GReaders);
  SetLength(GReaders, n + 1);
  GReaders[n].Name := AName;
  GReaders[n].Exts := AExtensions;
  GReaders[n].Detect := ADetect;
  GReaders[n].Read := ARead;
end;

procedure XVRegisterWriter(const AName, AExtensions: string; AWrite: TXVWriteFunc);
var n: Integer;
begin
  n := Length(GWriters);
  SetLength(GWriters, n + 1);
  GWriters[n].Name := AName;
  GWriters[n].Exts := AExtensions;
  GWriters[n].Write := AWrite;
end;

function XVReaderCount: Integer;
begin
  Result := Length(GReaders);
end;

function XVReaderName(I: Integer): string;
begin
  Result := GReaders[I].Name;
end;

function XVReaderExtensions(I: Integer): string;
begin
  Result := GReaders[I].Exts;
end;

function XVSupportedExtensions: string;
var
  i: Integer;
  sl: TStringList;
begin
  Result := '';
  sl := TStringList.Create;
  try
    for i := 0 to High(GReaders) do
    begin
      sl.Delimiter := ';';
      sl.StrictDelimiter := True;
      sl.DelimitedText := GReaders[i].Exts;
      while sl.Count > 0 do
      begin
        if Result <> '' then Result := Result + ';';
        Result := Result + '*.' + sl[0];
        sl.Delete(0);
      end;
    end;
  finally
    sl.Free;
  end;
end;

initialization
  GFS := DefaultFormatSettings;
  GFS.DecimalSeparator := '.';
  GFS.ThousandSeparator := #0;
end.
