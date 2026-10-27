unit XVGdiPlay;

{$mode delphi}{$H+}
{$R-}{$Q-}

// XelVectors - a GDI emulator shared by the WMF and EMF readers.
//
// It keeps the device context state (mapping mode, window / viewport, world
// transform, current position, selected pen / brush / font, colours, text
// alignment, fill mode, arc direction, clip region, path bracket, SaveDC
// stack) and the object table, and turns the drawing calls into elements of
// the document. Document space is the device space of the metafile.

interface

uses
  SysUtils, Classes, Math, XVModel, XVImageCodec;

const
  // GDI stock objects (EMF handles with the high bit set)
  STOCK_WHITE_BRUSH = 0;
  STOCK_LTGRAY_BRUSH = 1;
  STOCK_GRAY_BRUSH = 2;
  STOCK_DKGRAY_BRUSH = 3;
  STOCK_BLACK_BRUSH = 4;
  STOCK_NULL_BRUSH = 5;
  STOCK_WHITE_PEN = 6;
  STOCK_BLACK_PEN = 7;
  STOCK_NULL_PEN = 8;
  STOCK_DC_BRUSH = 18;
  STOCK_DC_PEN = 19;

type
  TGdiObjKind = (goNone, goPen, goBrush, goFont, goRegion, goPalette, goOther);

  TGdiPen = record
    Style: Cardinal;               // PS_* style, end cap and join bits
    Width: Double;                 // logical units, 0 = cosmetic
    Color: TXVColor;
    Dashes: TXVDoubles;            // PS_USERSTYLE entries
    Cosmetic: Boolean;
    BrushImage: Integer;           // pattern pens: not drawn with the image (colour only)
  end;

  TGdiBrush = record
    Style: Integer;                // BS_*
    Color: TXVColor;
    Hatch: Integer;
    Image: Integer;                // pattern brushes: index in Doc.Images
  end;

  TGdiFont = record
    Height, Width: Integer;
    Escapement, Orientation: Integer;
    Weight: Integer;
    Italic, Underline, Strike: Boolean;
    CharSet: Integer;
    Face: string;
  end;

  TGdiObj = record
    Kind: TGdiObjKind;
    Pen: TGdiPen;
    Brush: TGdiBrush;
    Font: TGdiFont;
    Region: TXVPath;               // device (document) coordinates
  end;

  TClipItem = record
    Path: TXVPath;
    Rule: TXVFillRule;
  end;

  TDCState = record
    MapMode: Integer;
    WinOrgX, WinOrgY, WinExtX, WinExtY: Double;
    VpOrgX, VpOrgY, VpExtX, VpExtY: Double;
    World: TXVMatrix;
    CurX, CurY: Double;            // logical
    Pen: TGdiPen;
    Brush: TGdiBrush;
    Font: TGdiFont;
    TextColor, BkColor: TXVColor;
    BkMode: Integer;               // 1 transparent, 2 opaque
    TextAlign: Cardinal;
    FillMode: Integer;             // 1 alternate, 2 winding
    ArcDir: Integer;               // 1 counter-clockwise, 2 clockwise
    MiterLimit: Double;
    Rop2: Integer;
    Clips: array of TClipItem;
    ClipSerial: Integer;
    CharExtra: Double;
  end;

  { TXVGdiPlayer }

  TXVGdiPlayer = class
  private
    FTotal: TXVMatrix;             // logical -> document
    FStack: array of TDCState;
    FSerial: Integer;
    FEmittedSerial: Integer;
    FOpenGroups: Integer;
    FHatchPatterns: array of Integer;
    procedure UpdateTotal;
    function BrushPaint(const B: TGdiBrush): TXVPaint;
    function PenStroke(const P: TGdiPen): TXVStroke;
    procedure EmitPath(const P: TXVPath; Fill, Stroke: Boolean; Closed: Boolean);
    procedure SetClips(const NewClips: array of TClipItem);
  public
    Doc: TXVDocument;
    S: TDCState;
    Objects: array of TGdiObj;
    DevPxPerMMX, DevPxPerMMY: Double;   // device resolution, for the metric mapping modes
    InPath: Boolean;
    PathBuf: TXVPath;                   // device coordinates
    IsWMF: Boolean;
    ViewportSet: Boolean;
    WmfVpX, WmfVpY: Double;             // WMF: the picture size in device units
    Bounds: TXVRect;                    // what was drawn, device units
    HaveBounds: Boolean;
    constructor Create(ADoc: TXVDocument);
    destructor Destroy; override;
    // mapping
    function Map(X, Y: Double): TXVPoint;
    function MapLen(L: Double): Double;
    property Total: TXVMatrix read FTotal;
    procedure SetMapMode(M: Integer);
    procedure SetWindowOrg(X, Y: Double);
    procedure SetWindowExt(X, Y: Double);
    procedure SetViewportOrg(X, Y: Double);
    procedure SetViewportExt(X, Y: Double);
    procedure SetWorld(const M: TXVMatrix);
    procedure ModifyWorld(const M: TXVMatrix; Mode: Integer);
    procedure ScaleWindowExt(XN, XD, YN, YD: Double);
    procedure ScaleViewportExt(XN, XD, YN, YD: Double);
    // state
    procedure SaveDC;
    procedure RestoreDC(N: Integer);
    // objects
    function FreeSlot: Integer;
    procedure SetObject(Index: Integer; const O: TGdiObj);
    procedure DeleteObject(Index: Integer);
    procedure SelectObject(Index: Cardinal);
    procedure SelectStock(N: Integer);
    function HatchImage(Hatch: Integer; Fg, Bg: TXVColor; Opaque: Boolean): Integer;
    // clipping (device paths)
    procedure ClipIntersect(const P: TXVPath; Rule: TXVFillRule);
    procedure ClipExclude(const P: TXVPath);
    procedure ClipReplace(const P: TXVPath; Rule: TXVFillRule);
    procedure ClipReset;
    procedure ClipOffset(DX, DY: Double);
    function RectPath(X1, Y1, X2, Y2: Double): TXVPath;      // logical rectangle -> device path
    // drawing (logical coordinates)
    procedure MoveTo(X, Y: Double);
    procedure LineTo(X, Y: Double);
    procedure Polyline(const Pts: array of TXVPoint; UseCur: Boolean);
    procedure Polygon(const Pts: array of TXVPoint);
    procedure PolyPolygon(const Pts: array of TXVPoint; const Counts: array of Integer);
    procedure PolyPolyline(const Pts: array of TXVPoint; const Counts: array of Integer);
    procedure PolyBezier(const Pts: array of TXVPoint; UseCur: Boolean);
    procedure PolyDraw(const Pts: array of TXVPoint; const Types: array of Byte);
    procedure Rectangle(L, T, R, B: Double);
    procedure RoundRect(L, T, R, B, W, H: Double);
    procedure Ellipse(L, T, R, B: Double);
    procedure ArcEx(L, T, R, B, XS, YS, XE, YE: Double; Kind: Integer);  // 0 arc, 1 chord, 2 pie, 3 arcto
    procedure AngleArc(CX, CY, R, StartDeg, SweepDeg: Double);
    procedure FillRect(L, T, R, B: Double; const Br: TGdiBrush);
    procedure FillDevicePath(const P: TXVPath; const Br: TGdiBrush; Rule: TXVFillRule);
    procedure FrameDevicePath(const P: TXVPath; const Br: TGdiBrush; W: Double);
    procedure SetPixel(X, Y: Double; C: TXVColor);
    // path bracket
    procedure BeginPath;
    procedure EndPath;
    procedure AbortPath;
    procedure CloseFigure;
    procedure FillPath;
    procedure StrokePath;
    procedure StrokeAndFillPath;
    procedure SelectClipPath(Mode: Integer);
    procedure WidenPath;
    // text: X / Y logical reference point, CharDX logical advances (may be nil)
    procedure TextOut(X, Y: Double; const Text: string; const CharDX: array of Double; Options: Cardinal;
      const OpaqueRect: TXVRect; HaveRect: Boolean);
    // images: Img drawn into the logical rectangle (X, Y, W, H) from the source rectangle
    procedure DrawImage(const Img: TXVImage; X, Y, W, H: Double; SX, SY, SW, SH: Integer; Rop: Cardinal);
    procedure Finish;
    procedure SyncClip;
  end;

function XVGdiDefaultState: TDCState;

implementation

function XVGdiDefaultState: TDCState;
begin
  Result := Default(TDCState);
  Result.MapMode := 1;
  Result.WinExtX := 1; Result.WinExtY := 1;
  Result.VpExtX := 1; Result.VpExtY := 1;
  Result.World := TXVMatrix.Identity;
  Result.Pen.Color := XV_BLACK;
  Result.Pen.Width := 0;
  Result.Pen.Cosmetic := True;
  Result.Pen.BrushImage := -1;
  Result.Brush.Style := 0;
  Result.Brush.Color := XV_WHITE;
  Result.Brush.Image := -1;
  Result.Font.Height := -12;
  Result.Font.Weight := 400;
  Result.Font.Face := 'Arial';
  Result.TextColor := XV_BLACK;
  Result.BkColor := XV_WHITE;
  Result.BkMode := 2;
  Result.FillMode := 1;
  Result.ArcDir := 1;
  Result.MiterLimit := 10;
  Result.Rop2 := 13;
end;

constructor TXVGdiPlayer.Create(ADoc: TXVDocument);
begin
  inherited Create;
  Doc := ADoc;
  S := XVGdiDefaultState;
  DevPxPerMMX := 96 / 25.4;
  DevPxPerMMY := 96 / 25.4;
  PathBuf.Clear;
  UpdateTotal;
end;

destructor TXVGdiPlayer.Destroy;
begin
  inherited Destroy;
end;

// ------------------------------ mapping ------------------------------------

procedure TXVGdiPlayer.UpdateTotal;
var
  sx, sy, wex, wey, vex, vey, k: Double;
  pg: TXVMatrix;
begin
  case S.MapMode of
    2: begin sx := DevPxPerMMX / 10; sy := -DevPxPerMMY / 10; end;          // MM_LOMETRIC
    3: begin sx := DevPxPerMMX / 100; sy := -DevPxPerMMY / 100; end;        // MM_HIMETRIC
    4: begin sx := DevPxPerMMX * 0.254; sy := -DevPxPerMMY * 0.254; end;    // MM_LOENGLISH
    5: begin sx := DevPxPerMMX * 0.0254; sy := -DevPxPerMMY * 0.0254; end;  // MM_HIENGLISH
    6: begin sx := DevPxPerMMX * 25.4 / 1440; sy := -DevPxPerMMY * 25.4 / 1440; end;  // MM_TWIPS
    7, 8:
      begin
        wex := S.WinExtX; wey := S.WinExtY;
        if Abs(wex) < 1e-12 then wex := 1;
        if Abs(wey) < 1e-12 then wey := 1;
        vex := S.VpExtX; vey := S.VpExtY;
        if IsWMF and not ViewportSet then
        begin
          // a WMF does not record the viewport: the player maps the first
          // window onto the picture
          if WmfVpX > 0 then vex := WmfVpX else vex := Abs(wex);
          if WmfVpY > 0 then vey := WmfVpY else vey := Abs(wey);
        end;
        sx := vex / wex; sy := vey / wey;
        if S.MapMode = 7 then
        begin
          k := Min(Abs(sx), Abs(sy));
          sx := Sign(sx) * k; sy := Sign(sy) * k;
          if sx = 0 then sx := k;
          if sy = 0 then sy := k;
        end;
      end;
  else
    begin sx := 1; sy := 1; end;                                          // MM_TEXT
  end;
  if S.MapMode in [7, 8] then
    pg := TXVMatrix.Make(sx, 0, 0, sy, S.VpOrgX - S.WinOrgX * sx, S.VpOrgY - S.WinOrgY * sy)
  else
    pg := TXVMatrix.Make(sx, 0, 0, sy, S.VpOrgX - S.WinOrgX * sx, S.VpOrgY - S.WinOrgY * sy);
  if IsWMF and not ViewportSet then
  begin
    pg.E := -S.WinOrgX * sx;
    pg.F := -S.WinOrgY * sy;
  end;
  FTotal := XVMul(pg, S.World);
end;

function TXVGdiPlayer.Map(X, Y: Double): TXVPoint;
begin
  Result := FTotal.Apply(X, Y);
end;

function TXVGdiPlayer.MapLen(L: Double): Double;
begin
  Result := L * FTotal.ScaleFactor;
end;

procedure TXVGdiPlayer.SetMapMode(M: Integer);
begin
  S.MapMode := M;
  UpdateTotal;
end;

procedure TXVGdiPlayer.SetWindowOrg(X, Y: Double);
begin
  S.WinOrgX := X; S.WinOrgY := Y;
  UpdateTotal;
end;

procedure TXVGdiPlayer.SetWindowExt(X, Y: Double);
begin
  if (X = 0) or (Y = 0) then Exit;
  S.WinExtX := X; S.WinExtY := Y;
  if IsWMF and (WmfVpX <= 0) then
  begin
    WmfVpX := Abs(X);
    WmfVpY := Abs(Y);
  end;
  UpdateTotal;
end;

procedure TXVGdiPlayer.SetViewportOrg(X, Y: Double);
begin
  S.VpOrgX := X; S.VpOrgY := Y;
  if IsWMF then ViewportSet := True;
  UpdateTotal;
end;

procedure TXVGdiPlayer.SetViewportExt(X, Y: Double);
begin
  if (X = 0) or (Y = 0) then Exit;
  S.VpExtX := X; S.VpExtY := Y;
  if IsWMF then ViewportSet := True;
  UpdateTotal;
end;

procedure TXVGdiPlayer.SetWorld(const M: TXVMatrix);
begin
  S.World := M;
  UpdateTotal;
end;

procedure TXVGdiPlayer.ModifyWorld(const M: TXVMatrix; Mode: Integer);
begin
  case Mode of
    1: S.World := TXVMatrix.Identity;          // MWT_IDENTITY
    2: S.World := XVMul(S.World, M);           // MWT_LEFTMULTIPLY: M first
    3: S.World := XVMul(M, S.World);           // MWT_RIGHTMULTIPLY
    4: S.World := M;                           // MWT_SET
  end;
  UpdateTotal;
end;

procedure TXVGdiPlayer.ScaleWindowExt(XN, XD, YN, YD: Double);
begin
  if (XD = 0) or (YD = 0) then Exit;
  S.WinExtX := S.WinExtX * XN / XD;
  S.WinExtY := S.WinExtY * YN / YD;
  UpdateTotal;
end;

procedure TXVGdiPlayer.ScaleViewportExt(XN, XD, YN, YD: Double);
begin
  if (XD = 0) or (YD = 0) then Exit;
  S.VpExtX := S.VpExtX * XN / XD;
  S.VpExtY := S.VpExtY * YN / YD;
  UpdateTotal;
end;

// ------------------------------ state --------------------------------------

procedure TXVGdiPlayer.SaveDC;
var n: Integer;
begin
  n := Length(FStack);
  if n >= 1024 then Exit;
  SetLength(FStack, n + 1);
  FStack[n] := S;
  FStack[n].Clips := Copy(S.Clips);
end;

procedure TXVGdiPlayer.RestoreDC(N: Integer);
var k: Integer;
begin
  if Length(FStack) = 0 then Exit;
  if N < 0 then k := Length(FStack) + N else k := N - 1;
  if k < 0 then k := 0;
  if k > High(FStack) then k := High(FStack);
  S := FStack[k];
  SetLength(FStack, k);
  UpdateTotal;
end;

// ------------------------------ objects ------------------------------------

function TXVGdiPlayer.FreeSlot: Integer;
var i: Integer;
begin
  for i := 0 to High(Objects) do
    if Objects[i].Kind = goNone then Exit(i);
  Result := Length(Objects);
  SetLength(Objects, Result + 1);
  Objects[Result].Kind := goNone;
end;

procedure TXVGdiPlayer.SetObject(Index: Integer; const O: TGdiObj);
var i: Integer;
begin
  if (Index < 0) or (Index > 65535) then Exit;
  if Index > High(Objects) then
  begin
    i := Length(Objects);
    SetLength(Objects, Index + 1);
    for i := i to Index do Objects[i].Kind := goNone;
  end;
  Objects[Index] := O;
end;

procedure TXVGdiPlayer.DeleteObject(Index: Integer);
begin
  if (Index >= 0) and (Index <= High(Objects)) then Objects[Index].Kind := goNone;
end;

procedure TXVGdiPlayer.SelectStock(N: Integer);
begin
  case N of
    STOCK_WHITE_BRUSH: begin S.Brush.Style := 0; S.Brush.Color := XV_WHITE; end;
    STOCK_LTGRAY_BRUSH: begin S.Brush.Style := 0; S.Brush.Color := XVRGB($C0, $C0, $C0); end;
    STOCK_GRAY_BRUSH: begin S.Brush.Style := 0; S.Brush.Color := XVRGB($80, $80, $80); end;
    STOCK_DKGRAY_BRUSH: begin S.Brush.Style := 0; S.Brush.Color := XVRGB($40, $40, $40); end;
    STOCK_BLACK_BRUSH: begin S.Brush.Style := 0; S.Brush.Color := XV_BLACK; end;
    STOCK_NULL_BRUSH: S.Brush.Style := 1;
    STOCK_WHITE_PEN: begin S.Pen := Default(TGdiPen); S.Pen.Color := XV_WHITE; S.Pen.Cosmetic := True; S.Pen.BrushImage := -1; end;
    STOCK_BLACK_PEN: begin S.Pen := Default(TGdiPen); S.Pen.Color := XV_BLACK; S.Pen.Cosmetic := True; S.Pen.BrushImage := -1; end;
    STOCK_NULL_PEN: begin S.Pen := Default(TGdiPen); S.Pen.Style := 5; S.Pen.BrushImage := -1; end;
    10..17: begin S.Font := XVGdiDefaultState.Font; if N in [10, 11, 16] then S.Font.Face := 'Courier New'; end;
    STOCK_DC_BRUSH, STOCK_DC_PEN: ;
  end;
end;

procedure TXVGdiPlayer.SelectObject(Index: Cardinal);
begin
  if (Index and $80000000) <> 0 then
  begin
    SelectStock(Index and $7FFFFFFF);
    Exit;
  end;
  if Integer(Index) > High(Objects) then Exit;
  case Objects[Index].Kind of
    goPen: S.Pen := Objects[Index].Pen;
    goBrush: S.Brush := Objects[Index].Brush;
    goFont: S.Font := Objects[Index].Font;
    goRegion: ClipReplace(Objects[Index].Region, frNonZero);    // WMF SelectObject of a region = SelectClipRgn
  end;
end;

function TXVGdiPlayer.HatchImage(Hatch: Integer; Fg, Bg: TXVColor; Opaque: Boolean): Integer;
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
        0: on := y = 7;                         // HS_HORIZONTAL
        1: on := x = 7;                         // HS_VERTICAL
        2: on := x = y;                         // HS_FDIAGONAL "\"
        3: on := x = 7 - y;                     // HS_BDIAGONAL "/"
        4: on := (x = 7) or (y = 7);            // HS_CROSS
        5: on := (x = y) or (x = 7 - y);        // HS_DIAGCROSS
      else
        on := True;
      end;
      if on then img.Px[y * 8 + x] := Fg
      else if Opaque then img.Px[y * 8 + x] := Bg
      else img.Px[y * 8 + x] := 0;
    end;
  Result := Doc.AddImageData(img);
end;

function TXVGdiPlayer.BrushPaint(const B: TGdiBrush): TXVPaint;
var
  img, pat: Integer;
begin
  case B.Style of
    0: Result := XVSolid(B.Color);                                           // BS_SOLID
    1: Result := XVNoPaint;                                                  // BS_NULL
    2: begin                                                                 // BS_HATCHED
         img := HatchImage(B.Hatch, B.Color, S.BkColor, S.BkMode = 2);
         pat := Doc.AddPattern(img, TXVMatrix.Identity, True);
         SetLength(FHatchPatterns, Length(FHatchPatterns) + 1);
         FHatchPatterns[High(FHatchPatterns)] := pat;
         Result := XVPatternPaint(pat, B.Color);
       end;
    3, 5, 6:                                                                 // pattern / DIB pattern
      if (B.Image >= 0) and (B.Image <= High(Doc.Images)) then
      begin
        pat := Doc.AddPattern(B.Image, TXVMatrix.Identity, True);
        SetLength(FHatchPatterns, Length(FHatchPatterns) + 1);
        FHatchPatterns[High(FHatchPatterns)] := pat;
        Result := XVPatternPaint(pat, XVImageAverage(Doc.Images[B.Image]));
      end
      else Result := XVSolid(XVRGB($80, $80, $80));
  else
    Result := XVSolid(B.Color);
  end;
end;

function TXVGdiPlayer.PenStroke(const P: TGdiPen): TXVStroke;
var
  st, i: Integer;
  w, u: Double;
begin
  Result := XVNoStroke;
  st := P.Style and $0F;
  if (st = 5) or (S.Rop2 = 11) then Exit;            // PS_NULL, R2_NOP
  Result.Paint := XVSolid(P.Color);
  if P.Cosmetic or (P.Width <= 0) then w := 0
  else w := MapLen(P.Width);
  // a one pixel wide pen of the reference device is a hairline
  if (w > 0) and (w < 1.01) and ((P.Style and $00010000) = 0) then w := 0;
  Result.Width := w;
  if (P.Style and $00010000) <> 0 then                 // PS_GEOMETRIC: caps and joins
  begin
    case P.Style and $0F00 of
      $0100: Result.Cap := lcSquare;
      $0200: Result.Cap := lcButt;
    else
      Result.Cap := lcRound;
    end;
    case P.Style and $F000 of
      $1000: Result.Join := ljBevel;
      $2000: Result.Join := ljMiter;
    else
      Result.Join := ljRound;
    end;
  end
  else
  begin
    Result.Cap := lcRound;
    Result.Join := ljRound;
    if IsWMF then begin Result.Cap := lcRound; Result.Join := ljRound; end;
  end;
  Result.MiterLimit := Max(1, S.MiterLimit);
  u := Max(w, 1);
  case st of
    1: Result.Dashes := [3 * u, 1 * u];
    2: Result.Dashes := [1 * u, 1 * u];
    3: Result.Dashes := [3 * u, 1 * u, 1 * u, 1 * u];
    4: Result.Dashes := [3 * u, 1 * u, 1 * u, 1 * u, 1 * u, 1 * u];
    7: if Length(P.Dashes) >= 2 then
       begin
         SetLength(Result.Dashes, Length(P.Dashes));
         for i := 0 to High(P.Dashes) do
           if P.Cosmetic then Result.Dashes[i] := Max(P.Dashes[i], 0.5)
           else Result.Dashes[i] := Max(MapLen(P.Dashes[i]), 0.1);
       end;
  end;
  if st in [1..4] then
    for i := 0 to High(Result.Dashes) do
      if Result.Cap <> lcButt then Result.Dashes[i] := Result.Dashes[i];
end;

// ------------------------------ clipping -----------------------------------

procedure TXVGdiPlayer.SetClips(const NewClips: array of TClipItem);
var i: Integer;
begin
  SetLength(S.Clips, Length(NewClips));
  for i := 0 to High(NewClips) do S.Clips[i] := NewClips[i];
  Inc(FSerial);
  S.ClipSerial := FSerial;
end;

function TXVGdiPlayer.RectPath(X1, Y1, X2, Y2: Double): TXVPath;
var p: array[0..3] of TXVPoint;
begin
  Result := Default(TXVPath);
  Result.Clear;
  p[0] := Map(X1, Y1); p[1] := Map(X2, Y1); p[2] := Map(X2, Y2); p[3] := Map(X1, Y2);
  Result.AddPolygon(p, True);
end;

procedure TXVGdiPlayer.ClipIntersect(const P: TXVPath; Rule: TXVFillRule);
var n: Integer;
begin
  n := Length(S.Clips);
  SetLength(S.Clips, n + 1);
  S.Clips[n].Path := P.Copy;
  S.Clips[n].Rule := Rule;
  Inc(FSerial);
  S.ClipSerial := FSerial;
end;

procedure TXVGdiPlayer.ClipExclude(const P: TXVPath);
var
  q: TXVPath;
  b: TXVRect;
  big: Double;
begin
  // everything except the shape: a large frame with the shape as a hole
  q := Default(TXVPath);
  q.Clear;
  big := 1e7;
  if HaveBounds then b := Bounds else b := XVRect(-big, -big, big, big);
  q.AddRect(-big, -big, 2 * big, 2 * big);
  q.Append(P);
  ClipIntersect(q, frEvenOdd);
end;

procedure TXVGdiPlayer.ClipReplace(const P: TXVPath; Rule: TXVFillRule);
var c: array of TClipItem;
begin
  SetLength(c, 1);
  c[0].Path := P.Copy;
  c[0].Rule := Rule;
  SetClips(c);
end;

procedure TXVGdiPlayer.ClipReset;
begin
  if Length(S.Clips) = 0 then Exit;
  SetClips([]);
end;

procedure TXVGdiPlayer.ClipOffset(DX, DY: Double);
var
  i: Integer;
  d: TXVPoint;
  m: TXVMatrix;
begin
  if Length(S.Clips) = 0 then Exit;
  d := FTotal.ApplyVec(DX, DY);
  m := TXVMatrix.Translate(d.X, d.Y);
  for i := 0 to High(S.Clips) do
  begin
    S.Clips[i].Path := S.Clips[i].Path.Copy;
    S.Clips[i].Path.Transform(m);
  end;
  Inc(FSerial);
  S.ClipSerial := FSerial;
end;

// the document's group nesting follows the clip list of the state
procedure TXVGdiPlayer.SyncClip;
var i, ci: Integer;
begin
  if S.ClipSerial = FEmittedSerial then Exit;
  while FOpenGroups > 0 do
  begin
    Doc.EndGroup;
    Dec(FOpenGroups);
  end;
  FEmittedSerial := S.ClipSerial;
  for i := 0 to High(S.Clips) do
  begin
    ci := Doc.AddClip(S.Clips[i].Path, S.Clips[i].Rule);
    Doc.BeginGroup(ci, 1);
    Inc(FOpenGroups);
  end;
end;

// ------------------------------ output -------------------------------------

procedure TXVGdiPlayer.EmitPath(const P: TXVPath; Fill, Stroke: Boolean; Closed: Boolean);
var
  fp: TXVPaint;
  st: TXVStroke;
  rule: TXVFillRule;
  b: TXVRect;
begin
  if P.NCmd = 0 then Exit;
  if InPath then
  begin
    PathBuf.Append(P);
    Exit;
  end;
  if S.Rop2 = 11 then Exit;                 // R2_NOP
  if Fill then fp := BrushPaint(S.Brush) else fp := XVNoPaint;
  if Stroke then st := PenStroke(S.Pen) else st := XVNoStroke;
  if (fp.Kind = pkNone) and (st.Paint.Kind = pkNone) then Exit;
  if S.FillMode = 2 then rule := frNonZero else rule := frEvenOdd;
  SyncClip;
  Doc.AddPath(P, fp, st, rule);
  if P.Bounds(b) then XVUnionRect(Bounds, HaveBounds, b);
end;

// ------------------------------ drawing ------------------------------------

procedure TXVGdiPlayer.MoveTo(X, Y: Double);
var d: TXVPoint;
begin
  S.CurX := X; S.CurY := Y;
  if InPath then
  begin
    d := Map(X, Y);
    PathBuf.MoveTo(d.X, d.Y);
  end;
end;

procedure TXVGdiPlayer.LineTo(X, Y: Double);
var
  p: TXVPath;
  a, b: TXVPoint;
begin
  a := Map(S.CurX, S.CurY); b := Map(X, Y);
  if InPath then
  begin
    if not PathBuf.HasCurrent then PathBuf.MoveTo(a.X, a.Y);
    PathBuf.LineTo(b.X, b.Y);
  end
  else
  begin
    p := Default(TXVPath);
    p.Clear;
    p.MoveTo(a.X, a.Y);
    p.LineTo(b.X, b.Y);
    EmitPath(p, False, True, False);
  end;
  S.CurX := X; S.CurY := Y;
end;

procedure TXVGdiPlayer.Polyline(const Pts: array of TXVPoint; UseCur: Boolean);
var
  p: TXVPath;
  i: Integer;
  d: TXVPoint;
begin
  if Length(Pts) = 0 then Exit;
  if InPath then
  begin
    if UseCur then
    begin
      if not PathBuf.HasCurrent then begin d := Map(S.CurX, S.CurY); PathBuf.MoveTo(d.X, d.Y); end;
    end
    else begin d := Map(Pts[0].X, Pts[0].Y); PathBuf.MoveTo(d.X, d.Y); end;
    for i := Ord(not UseCur) to High(Pts) do
    begin
      d := Map(Pts[i].X, Pts[i].Y);
      PathBuf.LineTo(d.X, d.Y);
    end;
  end
  else
  begin
    p := Default(TXVPath);
    p.Clear;
    if UseCur then begin d := Map(S.CurX, S.CurY); p.MoveTo(d.X, d.Y); end
    else begin d := Map(Pts[0].X, Pts[0].Y); p.MoveTo(d.X, d.Y); end;
    for i := Ord(not UseCur) to High(Pts) do
    begin
      d := Map(Pts[i].X, Pts[i].Y);
      p.LineTo(d.X, d.Y);
    end;
    EmitPath(p, False, True, False);
  end;
  if UseCur then begin S.CurX := Pts[High(Pts)].X; S.CurY := Pts[High(Pts)].Y; end;
end;

procedure TXVGdiPlayer.Polygon(const Pts: array of TXVPoint);
var
  p: TXVPath;
  i: Integer;
  d: TXVPoint;
begin
  if Length(Pts) < 2 then Exit;
  p := Default(TXVPath);
  p.Clear;
  for i := 0 to High(Pts) do
  begin
    d := Map(Pts[i].X, Pts[i].Y);
    if i = 0 then p.MoveTo(d.X, d.Y) else p.LineTo(d.X, d.Y);
  end;
  p.Close;
  EmitPath(p, True, True, True);
end;

procedure TXVGdiPlayer.PolyPolygon(const Pts: array of TXVPoint; const Counts: array of Integer);
var
  p: TXVPath;
  i, j, k: Integer;
  d: TXVPoint;
begin
  p := Default(TXVPath);
  p.Clear;
  k := 0;
  for i := 0 to High(Counts) do
  begin
    for j := 0 to Counts[i] - 1 do
    begin
      if k > High(Pts) then Break;
      d := Map(Pts[k].X, Pts[k].Y);
      if j = 0 then p.MoveTo(d.X, d.Y) else p.LineTo(d.X, d.Y);
      Inc(k);
    end;
    p.Close;
  end;
  EmitPath(p, True, True, True);
end;

procedure TXVGdiPlayer.PolyPolyline(const Pts: array of TXVPoint; const Counts: array of Integer);
var
  p: TXVPath;
  i, j, k: Integer;
  d: TXVPoint;
begin
  p := Default(TXVPath);
  p.Clear;
  k := 0;
  for i := 0 to High(Counts) do
    for j := 0 to Counts[i] - 1 do
    begin
      if k > High(Pts) then Break;
      d := Map(Pts[k].X, Pts[k].Y);
      if j = 0 then p.MoveTo(d.X, d.Y) else p.LineTo(d.X, d.Y);
      Inc(k);
    end;
  EmitPath(p, False, True, False);
end;

procedure TXVGdiPlayer.PolyBezier(const Pts: array of TXVPoint; UseCur: Boolean);
var
  p: TXVPath;
  i, st: Integer;
  a, b, c, d: TXVPoint;
  target: PXVPath;
begin
  if Length(Pts) = 0 then Exit;
  p := Default(TXVPath);
  p.Clear;
  if InPath then target := @PathBuf else target := @p;
  if UseCur then
  begin
    a := Map(S.CurX, S.CurY);
    if not (InPath and PathBuf.HasCurrent) then target^.MoveTo(a.X, a.Y);
    st := 0;
  end
  else
  begin
    a := Map(Pts[0].X, Pts[0].Y);
    target^.MoveTo(a.X, a.Y);
    st := 1;
  end;
  i := st;
  while i + 2 <= High(Pts) do
  begin
    b := Map(Pts[i].X, Pts[i].Y); c := Map(Pts[i + 1].X, Pts[i + 1].Y); d := Map(Pts[i + 2].X, Pts[i + 2].Y);
    target^.CubicTo(b.X, b.Y, c.X, c.Y, d.X, d.Y);
    Inc(i, 3);
  end;
  if UseCur then begin S.CurX := Pts[High(Pts)].X; S.CurY := Pts[High(Pts)].Y; end;
  if not InPath then EmitPath(p, False, True, False);
end;

// POLYDRAW: PT_MOVETO 6, PT_LINETO 2, PT_BEZIERTO 4, PT_CLOSEFIGURE 1
procedure TXVGdiPlayer.PolyDraw(const Pts: array of TXVPoint; const Types: array of Byte);
var
  p: TXVPath;
  i: Integer;
  a, b, c: TXVPoint;
  target: PXVPath;
begin
  p := Default(TXVPath);
  p.Clear;
  if InPath then target := @PathBuf else target := @p;
  a := Map(S.CurX, S.CurY);
  if not target^.HasCurrent then target^.MoveTo(a.X, a.Y);
  i := 0;
  while i <= High(Pts) do
  begin
    if i > High(Types) then Break;
    case Types[i] and $06 of
      6: begin a := Map(Pts[i].X, Pts[i].Y); target^.MoveTo(a.X, a.Y); end;
      2: begin a := Map(Pts[i].X, Pts[i].Y); target^.LineTo(a.X, a.Y); end;
      4: if i + 2 <= High(Pts) then
         begin
           a := Map(Pts[i].X, Pts[i].Y); b := Map(Pts[i + 1].X, Pts[i + 1].Y); c := Map(Pts[i + 2].X, Pts[i + 2].Y);
           target^.CubicTo(a.X, a.Y, b.X, b.Y, c.X, c.Y);
           Inc(i, 2);
         end;
    end;
    if (Types[Min(i, High(Types))] and 1) <> 0 then target^.Close;
    S.CurX := Pts[i].X; S.CurY := Pts[i].Y;
    Inc(i);
  end;
  if not InPath then EmitPath(p, False, True, False);
end;

procedure TXVGdiPlayer.Rectangle(L, T, R, B: Double);
var p: TXVPath;
begin
  p := RectPath(L, T, R, B);
  EmitPath(p, True, True, True);
end;

procedure TXVGdiPlayer.RoundRect(L, T, R, B, W, H: Double);
var
  p: TXVPath;
  x1, y1, x2, y2, rx, ry: Double;
begin
  x1 := Min(L, R); x2 := Max(L, R); y1 := Min(T, B); y2 := Max(T, B);
  rx := Abs(W) / 2; ry := Abs(H) / 2;
  p := Default(TXVPath);
  p.Clear;
  p.AddRoundRect(x1, y1, x2 - x1, y2 - y1, rx, ry);
  p.Transform(FTotal);
  EmitPath(p, True, True, True);
end;

procedure TXVGdiPlayer.Ellipse(L, T, R, B: Double);
var p: TXVPath;
begin
  p := Default(TXVPath);
  p.Clear;
  p.AddEllipse((L + R) / 2, (T + B) / 2, Abs(R - L) / 2, Abs(B - T) / 2);
  p.Transform(FTotal);
  EmitPath(p, True, True, True);
end;

procedure TXVGdiPlayer.ArcEx(L, T, R, B, XS, YS, XE, YE: Double; Kind: Integer);
var
  p, q: TXVPath;
  cx, cy, rx, ry, a1, a2, sw: Double;
  negative: Boolean;
begin
  cx := (L + R) / 2; cy := (T + B) / 2;
  rx := Abs(R - L) / 2; ry := Abs(B - T) / 2;
  if (rx <= 0) or (ry <= 0) then Exit;
  a1 := ArcTan2((YS - cy) / ry, (XS - cx) / rx);
  a2 := ArcTan2((YE - cy) / ry, (XE - cx) / rx);
  // the direction is the one seen on the device (y down): counter-clockwise
  // means decreasing angles when the logical y axis points down too
  negative := S.ArcDir <> 2;
  if FTotal.Det < 0 then negative := not negative;
  sw := a2 - a1;
  if negative then
    while sw >= -1e-12 do sw := sw - 2 * Pi
  else
    while sw <= 1e-12 do sw := sw + 2 * Pi;
  p := Default(TXVPath);
  p.Clear;
  if Kind = 3 then
  begin
    p.MoveTo(S.CurX, S.CurY);
    p.ArcCenter(cx, cy, rx, ry, 0, a1, sw, 2);
    S.CurX := cx + rx * Cos(a1 + sw);
    S.CurY := cy + ry * Sin(a1 + sw);
  end
  else
  begin
    p.ArcCenter(cx, cy, rx, ry, 0, a1, sw, 1);
    if Kind = 1 then p.Close
    else if Kind = 2 then
    begin
      p.LineTo(cx, cy);
      p.Close;
    end;
  end;
  p.Transform(FTotal);
  if InPath and (Kind = 3) and PathBuf.HasCurrent then
  begin
    // ArcTo continues the current figure
    q := p.Copy;
    q.Cmds[0] := pcLineTo;
    PathBuf.LineTo(q.Pts[0].X, q.Pts[0].Y);
    Delete(q.Cmds, 0, 1);
    Delete(q.Pts, 0, 1);
    Dec(q.NCmd); Dec(q.NPt);
    q.FOpen := False;
    PathBuf.Append(q);
    Exit;
  end;
  EmitPath(p, Kind in [1, 2], True, Kind in [1, 2]);
end;
procedure TXVGdiPlayer.AngleArc(CX, CY, R, StartDeg, SweepDeg: Double);
var
  p: TXVPath;
  sgn: Double;
begin
  // angles counter-clockwise in logical space with y down: negate
  p := Default(TXVPath);
  p.Clear;
  p.MoveTo(S.CurX, S.CurY);
  if FTotal.Det > 0 then sgn := -1 else sgn := 1;
  p.ArcCenter(CX, CY, R, R, 0, sgn * DegToRad(StartDeg), sgn * DegToRad(SweepDeg), 2);
  S.CurX := p.CurrentPoint.X; S.CurY := p.CurrentPoint.Y;
  p.Transform(FTotal);
  EmitPath(p, False, True, False);
end;

procedure TXVGdiPlayer.FillDevicePath(const P: TXVPath; const Br: TGdiBrush; Rule: TXVFillRule);
var fp: TXVPaint; b: TXVRect;
begin
  fp := BrushPaint(Br);
  if fp.Kind = pkNone then Exit;
  SyncClip;
  Doc.AddPath(P, fp, XVNoStroke, Rule);
  if P.Bounds(b) then XVUnionRect(Bounds, HaveBounds, b);
end;

procedure TXVGdiPlayer.FrameDevicePath(const P: TXVPath; const Br: TGdiBrush; W: Double);
var st: TXVStroke;
begin
  st := XVNoStroke;
  st.Paint := XVSolid(Br.Color);
  st.Width := W;
  SyncClip;
  Doc.AddPath(P, XVNoPaint, st, frNonZero);
end;

procedure TXVGdiPlayer.FillRect(L, T, R, B: Double; const Br: TGdiBrush);
begin
  FillDevicePath(RectPath(L, T, R, B), Br, frNonZero);
end;

procedure TXVGdiPlayer.SetPixel(X, Y: Double; C: TXVColor);
var
  p: TXVPath;
  d: TXVPoint;
begin
  d := Map(X, Y);
  p := Default(TXVPath);
  p.Clear;
  p.AddRect(d.X - 0.5, d.Y - 0.5, 1, 1);
  SyncClip;
  Doc.AddPath(p, XVSolid(C), XVNoStroke, frNonZero);
end;

// ------------------------------ paths --------------------------------------

procedure TXVGdiPlayer.BeginPath;
begin
  InPath := True;
  PathBuf.Clear;
end;

procedure TXVGdiPlayer.EndPath;
begin
  InPath := False;
end;

procedure TXVGdiPlayer.AbortPath;
begin
  InPath := False;
  PathBuf.Clear;
end;

procedure TXVGdiPlayer.CloseFigure;
begin
  PathBuf.Close;
end;

procedure TXVGdiPlayer.FillPath;
begin
  InPath := False;
  EmitPath(PathBuf, True, False, True);
  PathBuf.Clear;
end;

procedure TXVGdiPlayer.StrokePath;
begin
  InPath := False;
  EmitPath(PathBuf, False, True, False);
  PathBuf.Clear;
end;

procedure TXVGdiPlayer.StrokeAndFillPath;
begin
  InPath := False;
  EmitPath(PathBuf, True, True, True);
  PathBuf.Clear;
end;

procedure TXVGdiPlayer.SelectClipPath(Mode: Integer);
var rule: TXVFillRule;
begin
  InPath := False;
  if S.FillMode = 2 then rule := frNonZero else rule := frEvenOdd;
  case Mode of
    5: ClipReplace(PathBuf, rule);           // RGN_COPY
    4: ClipExclude(PathBuf);                 // RGN_DIFF
    2, 3:
      if Length(S.Clips) = 0 then ClipReset  // OR / XOR with "everything"
      else ClipReplace(PathBuf, rule);
  else
    ClipIntersect(PathBuf, rule);            // RGN_AND
  end;
  PathBuf.Clear;
end;

procedure TXVGdiPlayer.WidenPath;
begin
  // the widened outline is filled later: keep the centre line, it is stroked
  // by FillPath approximately (rare in practice)
end;

// ------------------------------ text ---------------------------------------

procedure TXVGdiPlayer.TextOut(X, Y: Double; const Text: string; const CharDX: array of Double; Options: Cardinal;
  const OpaqueRect: TXVRect; HaveRect: Boolean);
var
  f: TXVFont;
  em, sx, sy, ang, esc, total: Double;
  m: TXVMatrix;
  org, vx, vy: TXVPoint;
  idx, i, n: Integer;
  chars: TStringArray;
  cx: TXVDoubles;
  align: Cardinal;
  bg: TGdiBrush;
  rp: TXVPath;
begin
  // the opaque rectangle of ExtTextOut (ETO_OPAQUE)
  if HaveRect and ((Options and 2) <> 0) then
  begin
    bg := Default(TGdiBrush);
    bg.Style := 0;
    bg.Color := S.BkColor;
    rp := RectPath(OpaqueRect.Left, OpaqueRect.Top, OpaqueRect.Right, OpaqueRect.Bottom);
    FillDevicePath(rp, bg, frNonZero);
  end;
  if Text = '' then Exit;
  align := S.TextAlign;
  if (align and 1) <> 0 then begin X := S.CurX; Y := S.CurY; end;    // TA_UPDATECP
  f := XVDefaultFont;
  f.Family := S.Font.Face;
  if f.Family = '' then f.Family := 'Arial';
  em := Abs(S.Font.Height);
  if S.Font.Height > 0 then em := em * 0.86;       // cell height -> em height
  if em = 0 then em := 12;
  f.Size := em;
  f.Weight := S.Font.Weight;
  if f.Weight = 0 then f.Weight := 400;
  f.Italic := S.Font.Italic;
  f.Underline := S.Font.Underline;
  f.Strike := S.Font.Strike;
  // text space: glyphs upright on the device, logical sizes scaled onto it,
  // the baseline along the escapement (counter-clockwise as seen)
  org := Map(X, Y);
  vx := FTotal.ApplyVec(1, 0);
  vy := FTotal.ApplyVec(0, 1);
  sx := Hypot(vx.X, vx.Y);
  sy := Hypot(vy.X, vy.Y);
  if (sx < 1e-300) or (sy < 1e-300) then Exit;
  if vx.X >= 0 then ang := ArcTan2(vx.Y, vx.X) else ang := ArcTan2(-vx.Y, -vx.X);
  esc := DegToRad(S.Font.Escapement / 10);
  m := XVMul(TXVMatrix.Translate(org.X, org.Y), XVMul(TXVMatrix.Rotate(ang - esc), TXVMatrix.Scale(sx, sy)));
  SyncClip;
  idx := Doc.AddText(Text, f, m, XVSolid(S.TextColor));
  case align and 6 of
    6: Doc.Elements[idx].Anchor := taMiddle;
    2: Doc.Elements[idx].Anchor := taEnd;
  end;
  case align and 24 of
    24: Doc.Elements[idx].Baseline := tbAlphabetic;
    8: Doc.Elements[idx].Baseline := tbBottom;
  else
    Doc.Elements[idx].Baseline := tbTop;
  end;
  chars := XVUtf8Chars(Text);
  n := Length(chars);
  total := 0;
  if (Length(CharDX) >= n) and (n > 0) then
  begin
    SetLength(cx, n);
    for i := 0 to n - 1 do
    begin
      cx[i] := total;
      total := total + CharDX[i];
    end;
    // the anchor applies to the whole string: the positions carry it
    case align and 6 of
      6: for i := 0 to n - 1 do cx[i] := cx[i] - total / 2;
      2: for i := 0 to n - 1 do cx[i] := cx[i] - total;
    end;
    if n > 1 then
    begin
      Doc.Elements[idx].CharX := cx;
      Doc.Elements[idx].Anchor := taStart;
    end;
  end;
  if (align and 1) <> 0 then
  begin
    if total = 0 then total := n * em * 0.55;
    S.CurX := X + total;
  end;
  XVUnionRect(Bounds, HaveBounds, XVRect(org.X, org.Y, org.X, org.Y));
end;
// ------------------------------ images -------------------------------------

procedure TXVGdiPlayer.DrawImage(const Img: TXVImage; X, Y, W, H: Double; SX, SY, SW, SH: Integer; Rop: Cardinal);
var
  sub: TXVImage;
  i, j, ii: Integer;
  m: TXVMatrix;
  p0, p1, p2: TXVPoint;
  c: Cardinal;
  b: TXVRect;
begin
  if (Img.W <= 0) or (Img.H <= 0) then Exit;
  if SW <= 0 then begin SX := 0; SW := Img.W; end;
  if SH <= 0 then begin SY := 0; SH := Img.H; end;
  SX := EnsureRange(SX, 0, Img.W - 1); SY := EnsureRange(SY, 0, Img.H - 1);
  SW := Min(SW, Img.W - SX); SH := Min(SH, Img.H - SY);
  if (SW <= 0) or (SH <= 0) then Exit;
  sub := XVNewImage(SW, SH);
  for j := 0 to SH - 1 do
    for i := 0 to SW - 1 do
    begin
      c := Img.Px[(SY + j) * Img.W + SX + i];
      case Rop of
        $008800C6: if (c and $FFFFFF) = $FFFFFF then c := 0;    // SRCAND: white leaves the target
        $00EE0086, $00660046: if (c and $FFFFFF) = 0 then c := 0;  // SRCPAINT / SRCINVERT: black leaves it
        $00330008: c := (c and $FF000000) or (not c and $FFFFFF);  // NOTSRCCOPY
      end;
      sub.Px[j * SW + i] := c;
    end;
  ii := Doc.AddImageData(sub);
  // image pixel space -> logical rectangle -> device
  p0 := Map(X, Y); p1 := Map(X + W, Y); p2 := Map(X, Y + H);
  m := TXVMatrix.Make((p1.X - p0.X) / SW, (p1.Y - p0.Y) / SW, (p2.X - p0.X) / SH, (p2.Y - p0.Y) / SH, p0.X, p0.Y);
  SyncClip;
  Doc.AddImage(ii, m, 1);
  b := XVRect(Min(p0.X, Min(p1.X, p2.X)), Min(p0.Y, Min(p1.Y, p2.Y)), Max(p0.X, Max(p1.X, p2.X)),
    Max(p0.Y, Max(p1.Y, p2.Y)));
  XVUnionRect(Bounds, HaveBounds, b);
end;

procedure TXVGdiPlayer.Finish;
var
  i: Integer;
  px: Double;
begin
  while FOpenGroups > 0 do
  begin
    Doc.EndGroup;
    Dec(FOpenGroups);
  end;
  // hatches and pattern brushes: one tile pixel = one output pixel
  if (Doc.Width > 0) and (Doc.ViewBox.Width > 0) then px := Doc.ViewBox.Width / Doc.Width else px := 1;
  for i := 0 to High(FHatchPatterns) do
    Doc.Patterns[FHatchPatterns[i]].Matrix := TXVMatrix.Scale(px, px);
end;

end.
