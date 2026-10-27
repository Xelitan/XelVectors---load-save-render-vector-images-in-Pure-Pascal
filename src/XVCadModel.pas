unit XVCadModel;

{$mode delphi}{$H+}
{$R-}{$Q-}

// XelVectors - drawing model shared by the DXF and DWG readers, and its
// conversion into a vector document.
//
// The readers fill a TCadDrawing (layers, linetypes, text styles, blocks and
// the entities of model space); XVCadToDocument draws model space: entities
// are resolved against their layer and enclosing block insert (BYLAYER /
// BYBLOCK colours, linetypes, lineweights), placed through the object
// coordinate system of their extrusion and the insert transforms, and turned
// into paths (NURBS splines into Bezier segments), hatches (solid, gradient or
// pattern lines clipped to the boundary) and texts. The y axis is flipped
// at the end: CAD space points up.

interface

uses
  SysUtils, Classes, Math, XVModel, XVImageCodec;

type
  TCadVec = record
    X, Y, Z: Double;
  end;
  TCadVecs = array of TCadVec;

  TCadEdgeKind = (cekLine, cekArc, cekEllipse, cekSpline);

  TCadEdge = record
    Kind: TCadEdgeKind;
    P1, P2: TCadVec;                // line
    Center: TCadVec;                // arc / ellipse
    Radius: Double;
    StartAng, EndAng: Double;       // degrees
    CCW: Boolean;
    Major: TCadVec;                 // ellipse: major axis end point, relative
    Ratio: Double;
    Degree: Integer;                // spline
    Knots, Weights: TXVDoubles;
    Ctrl, Fit: TCadVecs;
  end;

  TCadLoop = record
    IsPolyline: Boolean;
    Pts: TCadVecs;
    Bulges: TXVDoubles;
    Closed: Boolean;
    Edges: array of TCadEdge;
  end;

  TCadPatLine = record
    Angle: Double;                  // degrees
    Base, Offset: TCadVec;
    Dashes: TXVDoubles;             // > 0 dash, < 0 gap, 0 dot
  end;

  TCadEntKind = (ceNone, ceLine, cePoint, ceCircle, ceArc, ceEllipse, cePolyline, ceSpline, ceHatch,
    ceText, ceMText, ceInsert, ceSolid, ceFace, ceLeader, ceWipeout, ceDimension, ceImage);

  TCadEntity = record
    Kind: TCadEntKind;
    Layer: string;
    Color: Integer;                 // ACI: 0 BYBLOCK, 256 BYLAYER
    TrueColor: Integer;             // $RRGGBB, -1 none
    Transparency: Double;           // 0 opaque .. 1 invisible
    LType: string;
    LTScale: Double;
    LWeight: Integer;               // 1/100 mm; -1 BYLAYER, -2 BYBLOCK, -3 default
    Invisible, PaperSpace: Boolean;
    Extrusion: TCadVec;
    Elevation: Double;
    Is3D: Boolean;                  // points in world coordinates (3D polylines, lines)
    Pts: TCadVecs;
    Bulges, SWidths, EWidths: TXVDoubles;
    Closed: Boolean;
    ConstWidth: Double;
    Center: TCadVec;
    Radius, StartAngle, EndAngle: Double;
    MajorAxis: TCadVec;
    Ratio, StartParam, EndParam: Double;
    Degree: Integer;
    Knots, Weights: TXVDoubles;
    FitPts: TCadVecs;
    // text
    Text: string;
    Height, Rotation, WidthFactor, Oblique: Double;
    HAlign, VAlign: Integer;
    AlignPt: TCadVec;
    HasAlignPt: Boolean;
    Style: string;
    Attachment: Integer;
    RefWidth, LineSpacing: Double;
    Direction: TCadVec;
    HasDirection: Boolean;
    Backwards, UpsideDown: Boolean;
    // insert / dimension
    Block: string;
    Scale: TCadVec;
    ColCount, RowCount: Integer;
    ColSpacing, RowSpacing: Double;
    // hatch
    Loops: array of TCadLoop;
    Solid: Boolean;
    PatternName: string;
    PatLines: array of TCadPatLine;
    HatchStyle: Integer;
    IsGradient: Boolean;
    GradName: string;
    GradColor1, GradColor2: Integer;
    GradAngle, GradShift: Double;
    // raster image / wipeout: one pixel along U and V from the insertion
    // point (Pts[0]), the size in pixels, the clip boundary in pixel
    // coordinates ((-0.5, -0.5) is the upper left corner)
    ImageFile: string;
    UVec, VVec, ImageSize: TCadVec;
    ClipPts: TCadVecs;
    ClipOn: Boolean;
  end;
  TCadEntities = array of TCadEntity;

  TCadLayer = record
    Name: string;
    Color, TrueColor: Integer;
    LType: string;
    LWeight: Integer;
    Off, Frozen: Boolean;
  end;

  TCadLType = record
    Name: string;
    Dashes: TXVDoubles;
  end;

  TCadStyle = record
    Name, Font, BigFont, Family: string;
    Height, WidthFactor, Oblique: Double;
    Bold, Italic: Boolean;
  end;

  TCadBlock = record
    Name: string;
    Base: TCadVec;
    Ents: TCadEntities;
  end;

  { TCadDrawing }

  TCadDrawing = class
  private
    FLayerIdx, FLTypeIdx, FStyleIdx, FBlockIdx: TStringList;
  public
    Layers: array of TCadLayer;
    LTypes: array of TCadLType;
    Styles: array of TCadStyle;
    Blocks: array of TCadBlock;
    Ents: TCadEntities;
    InsUnits: Integer;
    LTScaleGlobal: Double;
    ExtMin, ExtMax: TCadVec;
    HasExt: Boolean;
    BaseDir: string;                // folder of the drawing, for image files
    constructor Create;
    destructor Destroy; override;
    procedure BuildIndex;
    function FindLayer(const Name: string): Integer;
    function FindLType(const Name: string): Integer;
    function FindStyle(const Name: string): Integer;
    function FindBlock(const Name: string): Integer;
    function AddLayer(const L: TCadLayer): Integer;
    function AddBlock(const Name: string; const Base: TCadVec): Integer;
  end;

function CadVec(X, Y: Double; Z: Double = 0): TCadVec;
function XVAciColor(I: Integer): TXVColor;
function XVNewCadEntity(AKind: TCadEntKind): TCadEntity;
procedure XVCadToDocument(Cad: TCadDrawing; Doc: TXVDocument);
// "%%d", "%%c", "\U+00B0" ... in text values
function XVCadDecodeText(const S: string): string;

implementation

const
  ACI: array[0..255] of Cardinal = (
    $000000, $FF0000, $FFFF00, $00FF00, $00FFFF, $0000FF, $FF00FF, $FFFFFF,
    $808080, $C0C0C0, $FF0000, $FF7F7F, $A50000, $A55252, $7F0000, $7F3F3F,
    $4C0000, $4C2626, $260000, $261313, $FF3F00, $FF9F7F, $A52900, $A56752,
    $7F1F00, $7F4F3F, $4C1300, $4C2F26, $260900, $261713, $FF7F00, $FFBF7F,
    $A55200, $A57C52, $7F3F00, $7F5F3F, $4C2600, $4C3926, $261300, $261C13,
    $FFBF00, $FFDF7F, $A57C00, $A59152, $7F5F00, $7F6F3F, $4C3900, $4C4226,
    $261C00, $262113, $FFFF00, $FFFF7F, $A5A500, $A5A552, $7F7F00, $7F7F3F,
    $4C4C00, $4C4C26, $262600, $262613, $BFFF00, $DFFF7F, $7CA500, $91A552,
    $5F7F00, $6F7F3F, $394C00, $424C26, $1C2600, $212613, $7FFF00, $BFFF7F,
    $52A500, $7CA552, $3F7F00, $5F7F3F, $264C00, $394C26, $132600, $1C2613,
    $3FFF00, $9FFF7F, $29A500, $67A552, $1F7F00, $4F7F3F, $134C00, $2F4C26,
    $092600, $172613, $00FF00, $7FFF7F, $00A500, $52A552, $007F00, $3F7F3F,
    $004C00, $264C26, $002600, $132613, $00FF3F, $7FFF9F, $00A529, $52A567,
    $007F1F, $3F7F4F, $004C13, $264C2F, $002609, $135817, $00FF7F, $7FFFBF,
    $00A552, $52A57C, $007F3F, $3F7F5F, $004C26, $264C39, $002613, $13581C,
    $00FFBF, $7FFFDF, $00A57C, $52A591, $007F5F, $3F7F6F, $004C39, $264C42,
    $00261C, $135858, $00FFFF, $7FFFFF, $00A5A5, $52A5A5, $007F7F, $3F7F7F,
    $004C4C, $264C4C, $002626, $135858, $00BFFF, $7FDFFF, $007CA5, $5291A5,
    $005F7F, $3F6F7F, $00394C, $26427E, $001C26, $135858, $007FFF, $7FBFFF,
    $0052A5, $527CA5, $003F7F, $3F5F7F, $00264C, $26397E, $001326, $131C58,
    $003FFF, $7F9FFF, $0029A5, $5267A5, $001F7F, $3F4F7F, $00134C, $262F7E,
    $000926, $131758, $0000FF, $7F7FFF, $0000A5, $5252A5, $00007F, $3F3F7F,
    $00004C, $26267E, $000026, $131358, $3F00FF, $9F7FFF, $2900A5, $6752A5,
    $1F007F, $4F3F7F, $13004C, $2F267E, $090026, $171358, $7F00FF, $BF7FFF,
    $5200A5, $7C52A5, $3F007F, $5F3F7F, $26004C, $39267E, $130026, $1C1358,
    $BF00FF, $DF7FFF, $7C00A5, $9152A5, $5F007F, $6F3F7F, $39004C, $42264C,
    $1C0026, $581358, $FF00FF, $FF7FFF, $A500A5, $A552A5, $7F007F, $7F3F7F,
    $4C004C, $4C264C, $260026, $581358, $FF00BF, $FF7FDF, $A5007C, $A55291,
    $7F005F, $7F3F6F, $4C0039, $4C2642, $26001C, $581358, $FF007F, $FF7FBF,
    $A50052, $A5527C, $7F003F, $7F3F5F, $4C0026, $4C2639, $260013, $58131C,
    $FF003F, $FF7F9F, $A50029, $A55267, $7F001F, $7F3F4F, $4C0013, $4C262F,
    $260009, $581317, $000000, $656565, $666666, $999999, $CCCCCC, $FFFFFF);

function CadVec(X, Y: Double; Z: Double): TCadVec;
begin
  Result.X := X; Result.Y := Y; Result.Z := Z;
end;

function XVAciColor(I: Integer): TXVColor;
begin
  // 7 is white on a dark screen, black on paper
  if (I = 7) or (I <= 0) or (I > 255) then Exit(XV_BLACK);
  Result := $FF000000 or ACI[I];
end;

function XVNewCadEntity(AKind: TCadEntKind): TCadEntity;
begin
  Result := Default(TCadEntity);
  Result.Kind := AKind;
  Result.Layer := '0';
  Result.Color := 256;
  Result.TrueColor := -1;
  Result.LType := 'BYLAYER';
  Result.LTScale := 1;
  Result.LWeight := -1;
  Result.Extrusion := CadVec(0, 0, 1);
  Result.Scale := CadVec(1, 1, 1);
  Result.WidthFactor := 1;
  Result.ColCount := 1;
  Result.RowCount := 1;
  Result.Ratio := 1;
  Result.LineSpacing := 1;
  Result.GradColor1 := -1;
  Result.GradColor2 := -1;
end;

// ------------------------------ drawing ------------------------------------

constructor TCadDrawing.Create;
begin
  inherited Create;
  FLayerIdx := TStringList.Create;
  FLTypeIdx := TStringList.Create;
  FStyleIdx := TStringList.Create;
  FBlockIdx := TStringList.Create;
  LTScaleGlobal := 1;
end;

destructor TCadDrawing.Destroy;
begin
  FLayerIdx.Free; FLTypeIdx.Free; FStyleIdx.Free; FBlockIdx.Free;
  inherited Destroy;
end;

procedure TCadDrawing.BuildIndex;

  procedure Fill(L: TStringList; const Names: array of string);
  var i: Integer;
  begin
    L.Clear;
    L.Sorted := False;
    L.CaseSensitive := False;
    for i := 0 to High(Names) do L.AddObject(UpperCase(Names[i]), TObject(PtrInt(i)));
    L.Sorted := True;
  end;

var
  n: array of string;
  i: Integer;
begin
  SetLength(n, Length(Layers));
  for i := 0 to High(Layers) do n[i] := Layers[i].Name;
  Fill(FLayerIdx, n);
  SetLength(n, Length(LTypes));
  for i := 0 to High(LTypes) do n[i] := LTypes[i].Name;
  Fill(FLTypeIdx, n);
  SetLength(n, Length(Styles));
  for i := 0 to High(Styles) do n[i] := Styles[i].Name;
  Fill(FStyleIdx, n);
  SetLength(n, Length(Blocks));
  for i := 0 to High(Blocks) do n[i] := Blocks[i].Name;
  Fill(FBlockIdx, n);
end;

function FindIn(L: TStringList; const Name: string): Integer;
var i: Integer;
begin
  if L.Find(UpperCase(Name), i) then Result := Integer(PtrInt(L.Objects[i])) else Result := -1;
end;

function TCadDrawing.FindLayer(const Name: string): Integer;
begin
  Result := FindIn(FLayerIdx, Name);
end;

function TCadDrawing.FindLType(const Name: string): Integer;
begin
  Result := FindIn(FLTypeIdx, Name);
end;

function TCadDrawing.FindStyle(const Name: string): Integer;
begin
  Result := FindIn(FStyleIdx, Name);
end;

function TCadDrawing.FindBlock(const Name: string): Integer;
begin
  Result := FindIn(FBlockIdx, Name);
end;

function TCadDrawing.AddLayer(const L: TCadLayer): Integer;
begin
  Result := Length(Layers);
  SetLength(Layers, Result + 1);
  Layers[Result] := L;
end;

function TCadDrawing.AddBlock(const Name: string; const Base: TCadVec): Integer;
begin
  Result := Length(Blocks);
  SetLength(Blocks, Result + 1);
  Blocks[Result].Name := Name;
  Blocks[Result].Base := Base;
end;

// ------------------------------ text ---------------------------------------

function XVCadDecodeText(const S: string): string;
var
  i, n: Integer;
  c: string;
begin
  Result := '';
  i := 1;
  n := Length(S);
  while i <= n do
  begin
    if (S[i] = '%') and (i + 2 <= n) and (S[i + 1] = '%') then
    begin
      c := LowerCase(S[i + 2]);
      if c = 'd' then begin Result := Result + XVUtf8OfCode($B0); Inc(i, 3); Continue; end;
      if c = 'c' then begin Result := Result + XVUtf8OfCode($2300); Inc(i, 3); Continue; end;
      if c = 'p' then begin Result := Result + XVUtf8OfCode($B1); Inc(i, 3); Continue; end;
      if (c = 'u') or (c = 'o') or (c = 'k') then begin Inc(i, 3); Continue; end;
      if c = '%' then begin Result := Result + '%'; Inc(i, 3); Continue; end;
      if (S[i + 2] in ['0'..'9']) and (i + 4 <= n) then
      begin
        Result := Result + XVUtf8OfCode(StrToIntDef(Copy(S, i + 2, 3), 32));
        Inc(i, 5);
        Continue;
      end;
    end;
    if (S[i] = '\') and (i + 6 <= n) and ((S[i + 1] = 'U') or (S[i + 1] = 'u')) and (S[i + 2] = '+') then
    begin
      Result := Result + XVUtf8OfCode(StrToIntDef('$' + Copy(S, i + 3, 4), 63));
      Inc(i, 7);
      Continue;
    end;
    Result := Result + S[i];
    Inc(i);
  end;
end;

// MTEXT: formatting codes removed, lines split at \P; the first font name
// and the bold / italic flags of \f are reported
function MTextLines(const S: string; out Font: string; out Bold, Italic: Boolean): TStringArray;
var
  i, n, j: Integer;
  cur, t: string;
  c: Char;

  procedure Push;
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := XVCadDecodeText(cur);
    cur := '';
  end;

begin
  Result := nil;
  Font := ''; Bold := False; Italic := False;
  cur := '';
  i := 1;
  n := Length(S);
  while i <= n do
  begin
    c := S[i];
    if c = '\' then
    begin
      if i = n then Break;
      c := S[i + 1];
      case c of
        'P', 'X': begin Push; Inc(i, 2); end;
        '~': begin cur := cur + XVUtf8OfCode($A0); Inc(i, 2); end;
        '\', '{', '}': begin cur := cur + c; Inc(i, 2); end;
        'U', 'u':
          if (i + 6 <= n) and (S[i + 2] = '+') then
          begin
            cur := cur + XVUtf8OfCode(StrToIntDef('$' + Copy(S, i + 3, 4), 63));
            Inc(i, 7);
          end
          else Inc(i, 2);
        'L', 'l', 'O', 'o', 'K', 'k', 'N': Inc(i, 2);
        'S':
          begin
            // stacked fraction "\Sa^b;" -> "a/b"
            j := i + 2;
            t := '';
            while (j <= n) and (S[j] <> ';') do
            begin
              if S[j] in ['^', '#'] then t := t + '/' else t := t + S[j];
              Inc(j);
            end;
            cur := cur + t;
            i := j + 1;
          end;
        'f', 'F':
          begin
            j := i + 2;
            t := '';
            while (j <= n) and (S[j] <> ';') do begin t := t + S[j]; Inc(j); end;
            if Font = '' then
            begin
              Font := Copy(t, 1, Pos('|', t + '|') - 1);
              Bold := Pos('|b1', t) > 0;
              Italic := Pos('|i1', t) > 0;
            end;
            i := j + 1;
          end;
      else
        begin
          // \H, \W, \Q, \T, \A, \C, \c ... up to ";"
          j := i + 2;
          while (j <= n) and (S[j] <> ';') do Inc(j);
          i := j + 1;
        end;
      end;
      Continue;
    end;
    if (c = '{') or (c = '}') then begin Inc(i); Continue; end;
    if (c = '^') and (i < n) and (S[i + 1] = 'I') then begin cur := cur + ' '; Inc(i, 2); Continue; end;
    cur := cur + c;
    Inc(i);
  end;
  Push;
end;

// ------------------------------ conversion ---------------------------------

type
  TCadCtx = record
    M: TXVMatrix;                  // block space -> world (2D projection)
    Color: TXVColor;               // BYBLOCK values
    LType: string;
    LWeight: Integer;
    Layer: string;                 // the insert's layer, for entities on layer 0
    Depth: Integer;
  end;

  { TCadConv }

  TCadConv = class
    Cad: TCadDrawing;
    Doc: TXVDocument;
    UnitMM: Double;                // millimetres per drawing unit, 0 unknown
    ImageNames: TStringList;       // image files read so far
    ImageIdx: array of Integer;    // their document images, -1 unreadable
    function ImageIndex(const FileName: string): Integer;
    procedure Image(const E: TCadEntity; const Ctx: TCadCtx; C: TXVColor);
    procedure Ents(const L: TCadEntities; const Ctx: TCadCtx);
    procedure Entity(const E: TCadEntity; const Ctx: TCadCtx);
    function LayerOf(const E: TCadEntity; const Ctx: TCadCtx): Integer;
    function EntColor(const E: TCadEntity; const Ctx: TCadCtx; LayerI: Integer): TXVColor;
    function EntLType(const E: TCadEntity; const Ctx: TCadCtx; LayerI: Integer): string;
    function EntLWeight(const E: TCadEntity; const Ctx: TCadCtx; LayerI: Integer): Integer;
    function MakeStroke(const E: TCadEntity; const Ctx: TCadCtx; LayerI: Integer; const M: TXVMatrix): TXVStroke;
    procedure SplinePath(const Ctrl: TCadVecs; const W, Knots: TXVDoubles; Deg: Integer; const Fit: TCadVecs;
      Closed: Boolean; var P: TXVPath);
    procedure BulgePath(const Pts: TCadVecs; const Bulges: TXVDoubles; Closed: Boolean; var P: TXVPath);
    procedure LoopPath(const L: TCadLoop; var P: TXVPath);
    procedure Hatch(const E: TCadEntity; const Ctx: TCadCtx; const M: TXVMatrix; C: TXVColor);
    procedure Text(const E: TCadEntity; const Ctx: TCadCtx; const M: TXVMatrix; C: TXVColor);
    procedure MText(const E: TCadEntity; const Ctx: TCadCtx; const M: TXVMatrix; C: TXVColor);
    procedure Insert(const E: TCadEntity; const Ctx: TCadCtx; LayerI: Integer);
  end;

// arbitrary axis algorithm: object coordinates -> world, projected on XY
function OcsMatrix(const N: TCadVec; Elev: Double): TXVMatrix;
var
  ax, ay, nn: TCadVec;
  l: Double;
begin
  l := Sqrt(N.X * N.X + N.Y * N.Y + N.Z * N.Z);
  if l < 1e-12 then Exit(TXVMatrix.Identity);
  nn := CadVec(N.X / l, N.Y / l, N.Z / l);
  if (Abs(nn.X) < 1e-9) and (Abs(nn.Y) < 1e-9) and (nn.Z > 0) then Exit(TXVMatrix.Translate(0, 0));
  if (Abs(nn.X) < 1 / 64) and (Abs(nn.Y) < 1 / 64) then
    ax := CadVec(nn.Z, 0, -nn.X)              // Wy x N
  else
    ax := CadVec(-nn.Y, nn.X, 0);             // Wz x N
  l := Sqrt(ax.X * ax.X + ax.Y * ax.Y + ax.Z * ax.Z);
  ax := CadVec(ax.X / l, ax.Y / l, ax.Z / l);
  ay := CadVec(nn.Y * ax.Z - nn.Z * ax.Y, nn.Z * ax.X - nn.X * ax.Z, nn.X * ax.Y - nn.Y * ax.X);
  Result := TXVMatrix.Make(ax.X, ax.Y, ay.X, ay.Y, Elev * nn.X, Elev * nn.Y);
end;

function TCadConv.LayerOf(const E: TCadEntity; const Ctx: TCadCtx): Integer;
begin
  // entities of layer 0 inside a block take the layer of the insert
  if (E.Layer = '0') and (Ctx.Layer <> '') then Result := Cad.FindLayer(Ctx.Layer)
  else Result := Cad.FindLayer(E.Layer);
end;

function TCadConv.EntColor(const E: TCadEntity; const Ctx: TCadCtx; LayerI: Integer): TXVColor;
var lc: TXVColor;
begin
  if (LayerI >= 0) then
  begin
    if Cad.Layers[LayerI].TrueColor >= 0 then lc := $FF000000 or Cardinal(Cad.Layers[LayerI].TrueColor)
    else lc := XVAciColor(Abs(Cad.Layers[LayerI].Color));
  end
  else lc := XV_BLACK;
  if E.TrueColor >= 0 then Result := $FF000000 or Cardinal(E.TrueColor)
  else if E.Color = 256 then Result := lc
  else if E.Color = 0 then Result := Ctx.Color
  else Result := XVAciColor(Abs(E.Color));
  if E.Transparency > 0 then Result := XVMulAlpha(Result, 1 - E.Transparency);
end;

function TCadConv.EntLType(const E: TCadEntity; const Ctx: TCadCtx; LayerI: Integer): string;
begin
  Result := E.LType;
  if (Result = '') or SameText(Result, 'BYLAYER') then
  begin
    if LayerI >= 0 then Result := Cad.Layers[LayerI].LType else Result := '';
  end
  else if SameText(Result, 'BYBLOCK') then Result := Ctx.LType;
end;

function TCadConv.EntLWeight(const E: TCadEntity; const Ctx: TCadCtx; LayerI: Integer): Integer;
begin
  Result := E.LWeight;
  if Result = -1 then
  begin
    if LayerI >= 0 then Result := Cad.Layers[LayerI].LWeight else Result := -3;
  end
  else if Result = -2 then Result := Ctx.LWeight;
end;

function TCadConv.MakeStroke(const E: TCadEntity; const Ctx: TCadCtx; LayerI: Integer; const M: TXVMatrix): TXVStroke;
var
  lt: string;
  li, i, lw: Integer;
  sc, total: Double;
begin
  Result := XVStroke(EntColor(E, Ctx, LayerI), 0);
  Result.Cap := lcRound;
  Result.Join := ljRound;
  lw := EntLWeight(E, Ctx, LayerI);
  if (lw > 0) and (UnitMM > 0) then Result.Width := lw / 100 / UnitMM * M.ScaleFactor;
  if E.ConstWidth > 0 then
  begin
    Result.Width := E.ConstWidth * M.ScaleFactor;
    Result.Cap := lcButt;
    Result.Join := ljMiter;
  end;
  lt := EntLType(E, Ctx, LayerI);
  if (lt <> '') and not SameText(lt, 'CONTINUOUS') then
  begin
    li := Cad.FindLType(lt);
    if (li >= 0) and (Length(Cad.LTypes[li].Dashes) >= 2) then
    begin
      sc := Cad.LTScaleGlobal * E.LTScale * M.ScaleFactor;
      SetLength(Result.Dashes, Length(Cad.LTypes[li].Dashes));
      total := 0;
      for i := 0 to High(Result.Dashes) do
      begin
        // dots are short dashes; on / off alternate
        Result.Dashes[i] := Max(Abs(Cad.LTypes[li].Dashes[i]) * sc, 1e-9);
        total := total + Result.Dashes[i];
      end;
      if Odd(Length(Result.Dashes)) then
      begin
        SetLength(Result.Dashes, Length(Result.Dashes) + 1);
        Result.Dashes[High(Result.Dashes)] := 1e-9;
      end;
      if total <= 1e-12 then Result.Dashes := nil;
    end;
  end;
end;

// ---- splines ----

function FindSpan(n, p: Integer; u: Double; const U_: TXVDoubles): Integer;
var lo, hi, mid: Integer;
begin
  if u >= U_[n + 1] then Exit(n);
  if u <= U_[p] then Exit(p);
  lo := p; hi := n + 1;
  mid := (lo + hi) div 2;
  while (u < U_[mid]) or (u >= U_[mid + 1]) do
  begin
    if u < U_[mid] then hi := mid else lo := mid;
    mid := (lo + hi) div 2;
    if hi - lo <= 1 then Break;
  end;
  Result := mid;
end;

// homogeneous de Boor evaluation
procedure DeBoor(const Ctrl: TCadVecs; const W, U_: TXVDoubles; p: Integer; u: Double; out X, Y: Double);
var
  k, j, r, n: Integer;
  dx, dy, dw: array[0..15] of Double;
  a, den: Double;
begin
  n := High(Ctrl);
  k := FindSpan(n, p, u, U_);
  for j := 0 to p do
  begin
    r := k - p + j;
    if r < 0 then r := 0;
    if r > n then r := n;
    dw[j] := W[r];
    dx[j] := Ctrl[r].X * dw[j];
    dy[j] := Ctrl[r].Y * dw[j];
  end;
  for r := 1 to p do
    for j := p downto r do
    begin
      den := U_[j + 1 + k - r] - U_[j + k - p];
      if Abs(den) < 1e-300 then a := 0 else a := (u - U_[j + k - p]) / den;
      dx[j] := (1 - a) * dx[j - 1] + a * dx[j];
      dy[j] := (1 - a) * dy[j - 1] + a * dy[j];
      dw[j] := (1 - a) * dw[j - 1] + a * dw[j];
    end;
  if Abs(dw[p]) < 1e-300 then dw[p] := 1;
  X := dx[p] / dw[p];
  Y := dy[p] / dw[p];
end;

procedure TCadConv.SplinePath(const Ctrl: TCadVecs; const W, Knots: TXVDoubles; Deg: Integer; const Fit: TCadVecs;
  Closed: Boolean; var P: TXVPath);
var
  n, i, j, k, s, steps: Integer;
  U_, ww: TXVDoubles;
  rational, clamped: Boolean;
  q: TCadVecs;
  u0, u1, u, x, y, alpha: Double;
  c1x, c1y, c2x, c2y: Double;
  pts: TCadVecs;

  procedure InsertKnot(uu: Double);
  var
    kk, ii: Integer;
    nq: TCadVecs;
    nu: TXVDoubles;
  begin
    kk := FindSpan(High(q), Deg, uu, U_);
    SetLength(nq, Length(q) + 1);
    for ii := 0 to kk - Deg do nq[ii] := q[ii];
    for ii := kk - Deg + 1 to kk do
    begin
      if U_[ii + Deg] - U_[ii] > 1e-300 then alpha := (uu - U_[ii]) / (U_[ii + Deg] - U_[ii]) else alpha := 0;
      nq[ii].X := (1 - alpha) * q[ii - 1].X + alpha * q[ii].X;
      nq[ii].Y := (1 - alpha) * q[ii - 1].Y + alpha * q[ii].Y;
    end;
    for ii := kk + 1 to Length(q) do nq[ii] := q[ii - 1];
    SetLength(nu, Length(U_) + 1);
    for ii := 0 to kk do nu[ii] := U_[ii];
    nu[kk + 1] := uu;
    for ii := kk + 2 to High(nu) do nu[ii] := U_[ii - 1];
    q := nq;
    U_ := nu;
  end;

  function Mult(uu: Double): Integer;
  var ii: Integer;
  begin
    Result := 0;
    for ii := 0 to High(U_) do if Abs(U_[ii] - uu) < 1e-10 then Inc(Result);
  end;

begin
  n := Length(Ctrl);
  if (n < 2) or (Deg < 1) then
  begin
    // fit points only: a smooth curve through them (Catmull-Rom)
    if Length(Fit) < 2 then Exit;
    pts := Fit;
    if Closed then
    begin
      SetLength(pts, Length(Fit) + 1);
      pts[High(pts)] := Fit[0];
    end;
    P.MoveTo(pts[0].X, pts[0].Y);
    for i := 0 to High(pts) - 1 do
    begin
      if i > 0 then j := i - 1 else if Closed then j := High(pts) - 1 else j := 0;
      if i + 2 <= High(pts) then k := i + 2 else if Closed then k := 1 else k := High(pts);
      c1x := pts[i].X + (pts[i + 1].X - pts[j].X) / 6; c1y := pts[i].Y + (pts[i + 1].Y - pts[j].Y) / 6;
      c2x := pts[i + 1].X - (pts[k].X - pts[i].X) / 6; c2y := pts[i + 1].Y - (pts[k].Y - pts[i].Y) / 6;
      P.CubicTo(c1x, c1y, c2x, c2y, pts[i + 1].X, pts[i + 1].Y);
    end;
    Exit;
  end;
  if Deg > 15 then Deg := 15;
  if Deg > n - 1 then Deg := n - 1;
  // knots: given, or clamped uniform
  if Length(Knots) = n + Deg + 1 then U_ := Copy(Knots)
  else
  begin
    SetLength(U_, n + Deg + 1);
    for i := 0 to High(U_) do
      if i <= Deg then U_[i] := 0
      else if i >= n then U_[i] := n - Deg
      else U_[i] := i - Deg;
  end;
  for i := 1 to High(U_) do if U_[i] < U_[i - 1] then U_[i] := U_[i - 1];
  SetLength(ww, n);
  rational := False;
  for i := 0 to n - 1 do
  begin
    if i < Length(W) then ww[i] := W[i] else ww[i] := 1;
    if ww[i] <= 0 then ww[i] := 1;
    if Abs(ww[i] - 1) > 1e-9 then rational := True;
  end;
  clamped := True;
  for i := 1 to Deg do
    if (Abs(U_[i] - U_[0]) > 1e-10) or (Abs(U_[High(U_) - i] - U_[High(U_)]) > 1e-10) then clamped := False;
  if (not rational) and clamped and (Deg <= 3) then
  begin
    // Bezier extraction: every interior knot raised to multiplicity Deg
    q := Copy(Ctrl);
    i := Deg + 1;
    while i < Length(U_) - Deg - 1 do
    begin
      u := U_[i];
      if (u > U_[Deg]) and (u < U_[Length(U_) - Deg - 1]) then
        while Mult(u) < Deg do InsertKnot(u);
      // skip the knots equal to u
      j := i;
      while (j < Length(U_)) and (Abs(U_[j] - u) < 1e-10) do Inc(j);
      i := j;
      if Length(q) > 100000 then Break;
    end;
    P.MoveTo(q[0].X, q[0].Y);
    s := 0;
    while s + Deg <= High(q) do
    begin
      case Deg of
        1: P.LineTo(q[s + 1].X, q[s + 1].Y);
        2: P.QuadTo(q[s + 1].X, q[s + 1].Y, q[s + 2].X, q[s + 2].Y);
        3: P.CubicTo(q[s + 1].X, q[s + 1].Y, q[s + 2].X, q[s + 2].Y, q[s + 3].X, q[s + 3].Y);
      end;
      Inc(s, Deg);
    end;
    if Closed then P.Close;
    Exit;
  end;
  // general case: sampled
  u0 := U_[Deg]; u1 := U_[n];
  if u1 <= u0 then Exit;
  steps := Max(16, (n - Deg + 1) * 12);
  for i := 0 to steps do
  begin
    u := u0 + (u1 - u0) * i / steps;
    if i = steps then u := u1 - 1e-12 * (u1 - u0);
    DeBoor(Ctrl, ww, U_, Deg, u, x, y);
    if i = 0 then P.MoveTo(x, y) else P.LineTo(x, y);
  end;
  if Closed then P.Close;
end;

procedure TCadConv.BulgePath(const Pts: TCadVecs; const Bulges: TXVDoubles; Closed: Boolean; var P: TXVPath);
var
  i, n, j: Integer;
  b, ch, r, th: Double;
begin
  n := Length(Pts);
  if n = 0 then Exit;
  P.MoveTo(Pts[0].X, Pts[0].Y);
  for i := 0 to n - 1 do
  begin
    if (i = n - 1) and not Closed then Break;
    j := (i + 1) mod n;
    if i < Length(Bulges) then b := Bulges[i] else b := 0;
    if Abs(b) < 1e-9 then P.LineTo(Pts[j].X, Pts[j].Y)
    else
    begin
      ch := Hypot(Pts[j].X - Pts[i].X, Pts[j].Y - Pts[i].Y);
      if ch < 1e-12 then Continue;
      th := 4 * ArcTan(b);
      r := ch / 2 / Abs(Sin(th / 2));
      // positive bulge: counter-clockwise (the y axis points up here)
      P.ArcTo(r, r, 0, Abs(th) > Pi, b > 0, Pts[j].X, Pts[j].Y);
    end;
  end;
  if Closed then P.Close;
end;

procedure TCadConv.LoopPath(const L: TCadLoop; var P: TXVPath);
var
  i: Integer;
  e: TCadEdge;
  q: TXVPath;
  sw, a0, a1: Double;
  m: TXVMatrix;
  minor: TCadVec;
  first: Boolean;
  sp: TXVPoint;
begin
  if L.IsPolyline then
  begin
    BulgePath(L.Pts, L.Bulges, True, P);
    Exit;
  end;
  first := True;
  for i := 0 to High(L.Edges) do
  begin
    e := L.Edges[i];
    q := Default(TXVPath);
    q.Clear;
    case e.Kind of
      cekLine:
        begin
          q.MoveTo(e.P1.X, e.P1.Y);
          q.LineTo(e.P2.X, e.P2.Y);
        end;
      cekArc:
        begin
          a0 := DegToRad(e.StartAng); a1 := DegToRad(e.EndAng);
          if e.CCW then
          begin
            sw := a1 - a0;
            while sw <= 0 do sw := sw + 2 * Pi;
            q.ArcCenter(e.Center.X, e.Center.Y, e.Radius, e.Radius, 0, a0, sw, 1);
          end
          else
          begin
            // clockwise edges keep their angles mirrored
            sw := a1 - a0;
            while sw <= 0 do sw := sw + 2 * Pi;
            q.ArcCenter(e.Center.X, e.Center.Y, e.Radius, e.Radius, 0, -a0, -sw, 1);
          end;
        end;
      cekEllipse:
        begin
          a0 := DegToRad(e.StartAng); a1 := DegToRad(e.EndAng);
          sw := a1 - a0;
          while sw <= 0 do sw := sw + 2 * Pi;
          if not e.CCW then begin a0 := -a0; sw := -sw; end;
          minor := CadVec(-e.Major.Y * e.Ratio, e.Major.X * e.Ratio);
          q.ArcCenter(0, 0, 1, 1, 0, a0, sw, 1);
          m := TXVMatrix.Make(e.Major.X, e.Major.Y, minor.X, minor.Y, e.Center.X, e.Center.Y);
          q.Transform(m);
        end;
      cekSpline: SplinePath(e.Ctrl, e.Weights, e.Knots, e.Degree, e.Fit, False, q);
    end;
    if q.NCmd = 0 then Continue;
    if first then
    begin
      P.Append(q);
      first := False;
    end
    else
    begin
      // edges join: the first point of the edge continues the figure
      sp := q.Pts[0];
      if P.HasCurrent and (Hypot(sp.X - P.CurrentPoint.X, sp.Y - P.CurrentPoint.Y) > 1e-6) then P.LineTo(sp.X, sp.Y);
      q.Cmds[0] := pcLineTo;
      // a LineTo to the same point is harmless
      P.Append(q);
    end;
  end;
  P.Close;
end;

// pattern lines of a hatch, clipped to its boundary
procedure TCadConv.Hatch(const E: TCadEntity; const Ctx: TCadCtx; const M: TXVMatrix; C: TXVColor);
var
  P, lines: TXVPath;
  i, ci, nseg: Integer;
  b: TXVRect;
  g: TXVGradient;
  c1, c2: TXVColor;
  pl: TCadPatLine;
  dx, dy, nx, ny, on_, k, kmin, kmax, t, tmin, tmax, period, tpos, d: Double;
  corners: array[0..3] of TXVPoint;
  sx, sy, a: Double;
  j, di: Integer;
  st: TXVStroke;
  rule: TXVFillRule;
  inv: TXVMatrix;
  bw: TXVRect;
  tooMany: Boolean;
  gi: Integer;
begin
  P := Default(TXVPath);
  P.Clear;
  for i := 0 to High(E.Loops) do LoopPath(E.Loops[i], P);
  if P.NCmd = 0 then Exit;
  rule := frEvenOdd;
  P.Transform(M);
  if not P.Bounds(b) then Exit;
  if E.IsGradient then
  begin
    if E.GradColor1 >= 0 then c1 := $FF000000 or Cardinal(E.GradColor1) else c1 := C;
    if E.GradColor2 >= 0 then c2 := $FF000000 or Cardinal(E.GradColor2) else c2 := XV_WHITE;
    g := Default(TXVGradient);
    g.Matrix := TXVMatrix.Identity;
    SetLength(g.Stops, 2);
    if Pos('SPHERICAL', UpperCase(E.GradName)) > 0 then
    begin
      g.Kind := gkRadial;
      g.CX := (b.Left + b.Right) / 2; g.CY := (b.Top + b.Bottom) / 2;
      g.R := Hypot(b.Width, b.Height) / 2; g.FX := g.CX; g.FY := g.CY;
      if Pos('INV', UpperCase(E.GradName)) > 0 then begin g.Stops[0].Color := c2; g.Stops[1].Color := c1; end
      else begin g.Stops[0].Color := c1; g.Stops[1].Color := c2; end;
    end
    else
    begin
      g.Kind := gkLinear;
      a := E.GradAngle;
      g.X1 := (b.Left + b.Right) / 2 - Cos(a) * b.Width / 2; g.Y1 := (b.Top + b.Bottom) / 2 - Sin(a) * b.Height / 2;
      g.X2 := (b.Left + b.Right) / 2 + Cos(a) * b.Width / 2; g.Y2 := (b.Top + b.Bottom) / 2 + Sin(a) * b.Height / 2;
      if Pos('CYLINDER', UpperCase(E.GradName)) > 0 then
      begin
        SetLength(g.Stops, 3);
        if Pos('INV', UpperCase(E.GradName)) > 0 then
        begin
          g.Stops[0].Color := c2; g.Stops[1].Color := c1; g.Stops[2].Color := c2;
        end
        else begin g.Stops[0].Color := c1; g.Stops[1].Color := c2; g.Stops[2].Color := c1; end;
        g.Stops[1].Offset := 0.5; g.Stops[2].Offset := 1;
      end
      else
      begin
        g.Stops[0].Color := c1; g.Stops[1].Color := c2;
        if Pos('INV', UpperCase(E.GradName)) > 0 then begin g.Stops[0].Color := c2; g.Stops[1].Color := c1; end;
      end;
    end;
    g.Stops[0].Offset := 0;
    g.Stops[High(g.Stops)].Offset := 1;
    gi := Doc.AddGradient(g);
    Doc.AddPath(P, XVGradientPaint(gi, XVLerpColor(c1, c2, 0.5)), XVNoStroke, rule);
    Exit;
  end;
  if E.Solid or (Length(E.PatLines) = 0) then
  begin
    Doc.AddPath(P, XVSolid(C), XVNoStroke, rule);
    Exit;
  end;
  // pattern lines in world space, generated over the boundary's box
  inv := M.Invert;
  bw := XVRect(1e300, 1e300, -1e300, -1e300);
  corners[0] := inv.Apply(b.Left, b.Top); corners[1] := inv.Apply(b.Right, b.Top);
  corners[2] := inv.Apply(b.Left, b.Bottom); corners[3] := inv.Apply(b.Right, b.Bottom);
  lines := Default(TXVPath);
  lines.Clear;
  nseg := 0;
  tooMany := False;
  for i := 0 to High(E.PatLines) do
  begin
    pl := E.PatLines[i];
    dx := Cos(DegToRad(pl.Angle)); dy := Sin(DegToRad(pl.Angle));
    nx := -dy; ny := dx;
    d := pl.Offset.X * nx + pl.Offset.Y * ny;          // line spacing across
    if Abs(d) < 1e-9 then Continue;
    kmin := 1e300; kmax := -1e300; tmin := 1e300; tmax := -1e300;
    for j := 0 to 3 do
    begin
      k := ((corners[j].X - pl.Base.X) * nx + (corners[j].Y - pl.Base.Y) * ny) / d;
      kmin := Min(kmin, k); kmax := Max(kmax, k);
    end;
    if (kmax - kmin) > 20000 then begin tooMany := True; Break; end;
    period := 0;
    for di := 0 to High(pl.Dashes) do period := period + Abs(pl.Dashes[di]);
    for ci := Floor(kmin) to Ceil(kmax) do
    begin
      sx := pl.Base.X + ci * pl.Offset.X;
      sy := pl.Base.Y + ci * pl.Offset.Y;
      tmin := 1e300; tmax := -1e300;
      for j := 0 to 3 do
      begin
        t := (corners[j].X - sx) * dx + (corners[j].Y - sy) * dy;
        tmin := Min(tmin, t); tmax := Max(tmax, t);
      end;
      if (Length(pl.Dashes) = 0) or (period < 1e-9) then
      begin
        lines.MoveTo(sx + tmin * dx, sy + tmin * dy);
        lines.LineTo(sx + tmax * dx, sy + tmax * dy);
        Inc(nseg);
      end
      else
      begin
        if (tmax - tmin) / period > 5000 then begin tooMany := True; Break; end;
        tpos := Floor(tmin / period) * period;
        while tpos < tmax do
        begin
          for di := 0 to High(pl.Dashes) do
          begin
            on_ := pl.Dashes[di];
            if on_ >= 0 then
            begin
              // a dot is a very short dash
              if on_ = 0 then on_ := period * 0.01;
              if tpos + on_ > tmin then
              begin
                lines.MoveTo(sx + tpos * dx, sy + tpos * dy);
                lines.LineTo(sx + (tpos + on_) * dx, sy + (tpos + on_) * dy);
                Inc(nseg);
              end;
              tpos := tpos + Abs(pl.Dashes[di]);
            end
            else tpos := tpos - on_;
          end;
          if nseg > 400000 then begin tooMany := True; Break; end;
        end;
      end;
      if tooMany then Break;
    end;
    if tooMany then Break;
  end;
  if tooMany or (lines.NCmd = 0) then
  begin
    // too fine to draw line by line: a tinted fill instead
    Doc.AddPath(P, XVSolid(XVMulAlpha(C, 0.35)), XVNoStroke, rule);
    Exit;
  end;
  lines.Transform(M);
  st := XVStroke(C, 0);
  Doc.BeginGroup(Doc.AddClip(P, rule), 1);
  Doc.AddPath(lines, XVNoPaint, st, frNonZero);
  Doc.EndGroup;
end;

function StyleFont(Cad: TCadDrawing; const StyleName: string; out WF, Obl: Double; out Bold, Italic: Boolean): string;
var
  si: Integer;
  f: string;
begin
  Result := 'Arial';
  WF := 1; Obl := 0; Bold := False; Italic := False;
  si := Cad.FindStyle(StyleName);
  if si < 0 then Exit;
  WF := Cad.Styles[si].WidthFactor;
  if WF <= 0 then WF := 1;
  Obl := Cad.Styles[si].Oblique;
  Bold := Cad.Styles[si].Bold;
  Italic := Cad.Styles[si].Italic;
  if Cad.Styles[si].Family <> '' then Exit(Cad.Styles[si].Family);
  f := LowerCase(ChangeFileExt(ExtractFileName(Cad.Styles[si].Font), ''));
  if f = '' then Exit;
  if (f = 'txt') or (f = 'simplex') or (f = 'romans') or (f = 'isocp') or (f = 'iso') or (f = 'monotxt') then Exit('Arial');
  if (f = 'arial') or (f = 'arialbd') then Exit('Arial');
  if (f = 'times') or (f = 'romanc') or (f = 'romand') or (f = 'romant') then Exit('Times New Roman');
  if Pos('cour', f) = 1 then Exit('Courier New');
  if ExtractFileExt(Cad.Styles[si].Font) <> '' then
  begin
    if SameText(ExtractFileExt(Cad.Styles[si].Font), '.ttf') or SameText(ExtractFileExt(Cad.Styles[si].Font), '.otf') then
    begin
      Result := ChangeFileExt(ExtractFileName(Cad.Styles[si].Font), '');
      if Length(Result) > 0 then Result[1] := UpCase(Result[1]);
    end;
  end
  else Result := Cad.Styles[si].Font;
end;

const
  CAD_EM = 1.4;                    // em size of a font from its cap height

procedure TCadConv.Text(const E: TCadEntity; const Ctx: TCadCtx; const M: TXVMatrix; C: TXVColor);
var
  font: TXVFont;
  pos: TCadVec;
  wf, obl, h, dy: Double;
  tm: TXVMatrix;
  bold, italic: Boolean;
  anchor: TXVTextAnchor;
  s: string;
  idx: Integer;
begin
  s := XVCadDecodeText(E.Text);
  if Trim(s) = '' then Exit;
  font := XVDefaultFont;
  font.Family := StyleFont(Cad, E.Style, wf, obl, bold, italic);
  if E.WidthFactor > 0 then wf := E.WidthFactor;
  if E.Oblique <> 0 then obl := E.Oblique;
  h := E.Height;
  if h <= 0 then h := 2.5;
  font.Size := h * CAD_EM;
  if bold then font.Weight := 700;
  font.Italic := italic;
  if (E.HAlign <> 0) or (E.VAlign <> 0) then
  begin
    if E.HasAlignPt then pos := E.AlignPt else pos := E.Pts[0];
  end
  else if Length(E.Pts) > 0 then pos := E.Pts[0]
  else pos := CadVec(0, 0);
  if (E.HAlign = 3) or (E.HAlign = 5) then
  begin
    // aligned / fit: between the two points, from the first one
    if Length(E.Pts) > 0 then pos := E.Pts[0];
  end;
  anchor := taStart;
  case E.HAlign of
    1, 4: anchor := taMiddle;
    2: anchor := taEnd;
  end;
  dy := 0;
  case E.VAlign of
    1: dy := -0.3 * h;
    2: dy := h / 2;
    3: dy := h;
  end;
  if E.HAlign = 4 then dy := h / 2;
  // text space (y down) in object coordinates (y up)
  tm := XVMul(TXVMatrix.Translate(pos.X, pos.Y), TXVMatrix.Rotate(DegToRad(E.Rotation)));
  tm := XVMul(tm, TXVMatrix.Scale(wf, -1));
  if obl <> 0 then tm := XVMul(tm, TXVMatrix.SkewX(-DegToRad(obl)));
  if E.Backwards then tm := XVMul(tm, TXVMatrix.Scale(-1, 1));
  if E.UpsideDown then tm := XVMul(tm, TXVMatrix.Scale(1, -1));
  tm := XVMul(tm, TXVMatrix.Translate(0, dy));
  idx := Doc.AddText(s, font, XVMul(M, tm), XVSolid(C), anchor);
  if idx < 0 then ;
end;

procedure TCadConv.MText(const E: TCadEntity; const Ctx: TCadCtx; const M: TXVMatrix; C: TXVColor);
var
  lines, wrapped: TStringArray;
  fnt, f2, w: string;
  bold, italic, b2, i2: Boolean;
  font: TXVFont;
  h, sp, total, base, wf, obl, rot, ww, cw: Double;
  i, j, att, cut: Integer;
  anchor: TXVTextAnchor;
  tm: TXVMatrix;
  pos: TCadVec;
  words: TStringArray;
  cur: string;
begin
  lines := MTextLines(E.Text, f2, b2, i2);
  font := XVDefaultFont;
  fnt := StyleFont(Cad, E.Style, wf, obl, bold, italic);
  if f2 <> '' then fnt := f2;
  font.Family := fnt;
  if b2 then bold := True;
  if i2 then italic := True;
  h := E.Height;
  if h <= 0 then h := 2.5;
  font.Size := h * CAD_EM;
  if bold then font.Weight := 700;
  font.Italic := italic;
  // word wrap at the reference width (estimated advances)
  if E.RefWidth > 0 then
  begin
    wrapped := nil;
    for i := 0 to High(lines) do
    begin
      words := lines[i].Split([' ']);
      cur := '';
      for j := 0 to High(words) do
      begin
        if cur = '' then w := words[j] else w := cur + ' ' + words[j];
        if (cur <> '') and (XVEstimateTextWidth(font, w) > E.RefWidth * 1.02) then
        begin
          SetLength(wrapped, Length(wrapped) + 1);
          wrapped[High(wrapped)] := cur;
          cur := words[j];
        end
        else cur := w;
      end;
      SetLength(wrapped, Length(wrapped) + 1);
      wrapped[High(wrapped)] := cur;
    end;
    lines := wrapped;
  end;
  if Length(lines) = 0 then Exit;
  sp := h * 5 / 3 * Max(E.LineSpacing, 0.25);
  total := h + (Length(lines) - 1) * sp;
  att := E.Attachment;
  if (att < 1) or (att > 9) then att := 1;
  case (att - 1) mod 3 of
    1: anchor := taMiddle;
    2: anchor := taEnd;
  else
    anchor := taStart;
  end;
  case (att - 1) div 3 of
    0: base := h;
    1: base := h - total / 2;
  else
    base := h - total;
  end;
  if E.HasDirection and ((Abs(E.Direction.X) > 1e-12) or (Abs(E.Direction.Y) > 1e-12)) then
    rot := ArcTan2(E.Direction.Y, E.Direction.X)
  else rot := DegToRad(E.Rotation);
  if Length(E.Pts) > 0 then pos := E.Pts[0] else pos := CadVec(0, 0);
  for i := 0 to High(lines) do
  begin
    if Trim(lines[i]) = '' then Continue;
    tm := XVMul(TXVMatrix.Translate(pos.X, pos.Y), TXVMatrix.Rotate(rot));
    tm := XVMul(tm, TXVMatrix.Scale(1, -1));
    tm := XVMul(tm, TXVMatrix.Translate(0, base + i * sp));
    Doc.AddText(lines[i], font, XVMul(M, tm), XVSolid(C), anchor);
  end;
  if cw = 0 then ;
  if ww = 0 then ;
  if cut = 0 then ;
end;

procedure TCadConv.Insert(const E: TCadEntity; const Ctx: TCadCtx; LayerI: Integer);
var
  bi, r, c: Integer;
  C2: TCadCtx;
  m, base: TXVMatrix;
  b: TCadBlock;
begin
  if Ctx.Depth > 16 then Exit;
  bi := Cad.FindBlock(E.Block);
  if bi < 0 then Exit;
  b := Cad.Blocks[bi];
  C2 := Ctx;
  C2.Depth := Ctx.Depth + 1;
  C2.Color := EntColor(E, Ctx, LayerI);
  C2.LType := EntLType(E, Ctx, LayerI);
  C2.LWeight := EntLWeight(E, Ctx, LayerI);
  if (E.Layer <> '0') or (Ctx.Layer = '') then C2.Layer := E.Layer;
  if E.Kind = ceDimension then
  begin
    // dimension blocks are drawn where they are
    C2.M := Ctx.M;
    Ents(b.Ents, C2);
    Exit;
  end;
  base := TXVMatrix.Translate(-b.Base.X, -b.Base.Y);
  for r := 0 to Max(1, E.RowCount) - 1 do
    for c := 0 to Max(1, E.ColCount) - 1 do
    begin
      m := XVMul(Ctx.M, OcsMatrix(E.Extrusion, 0));
      m := XVMul(m, TXVMatrix.Translate(E.Pts[0].X, E.Pts[0].Y));
      m := XVMul(m, TXVMatrix.Rotate(DegToRad(E.Rotation)));
      m := XVMul(m, TXVMatrix.Translate(c * E.ColSpacing, r * E.RowSpacing));
      m := XVMul(m, TXVMatrix.Scale(E.Scale.X, E.Scale.Y));
      C2.M := XVMul(m, base);
      Ents(b.Ents, C2);
    end;
end;

procedure TCadConv.Entity(const E: TCadEntity; const Ctx: TCadCtx);
var
  li, i: Integer;
  P: TXVPath;
  M: TXVMatrix;
  col: TXVColor;
  st: TXVStroke;
  sw, a0: Double;
  minor, nn: TCadVec;
  q: array[0..3] of TXVPoint;
  fill: Boolean;
begin
  if E.Invisible or E.PaperSpace then Exit;
  li := LayerOf(E, Ctx);
  if (li >= 0) and (Cad.Layers[li].Off or Cad.Layers[li].Frozen) then Exit;
  col := EntColor(E, Ctx, li);
  if (E.Kind in [ceLine, ceFace, ceLeader]) or ((E.Kind = cePolyline) and E.Is3D) or
     (E.Kind in [ceSpline, ceEllipse]) then M := Ctx.M
  else M := XVMul(Ctx.M, OcsMatrix(E.Extrusion, E.Elevation));
  P := Default(TXVPath);
  P.Clear;
  case E.Kind of
    ceLine:
      if Length(E.Pts) >= 2 then
      begin
        P.MoveTo(E.Pts[0].X, E.Pts[0].Y);
        P.LineTo(E.Pts[1].X, E.Pts[1].Y);
      end;
    ceLeader:
      begin
        for i := 0 to High(E.Pts) do
          if i = 0 then P.MoveTo(E.Pts[i].X, E.Pts[i].Y) else P.LineTo(E.Pts[i].X, E.Pts[i].Y);
      end;
    ceCircle: if E.Radius > 0 then P.AddEllipse(E.Center.X, E.Center.Y, E.Radius, E.Radius);
    ceArc:
      if E.Radius > 0 then
      begin
        sw := E.EndAngle - E.StartAngle;
        while sw <= 0 do sw := sw + 360;
        while sw > 360 do sw := sw - 360;
        P.ArcCenter(E.Center.X, E.Center.Y, E.Radius, E.Radius, 0, DegToRad(E.StartAngle), DegToRad(sw), 1);
      end;
    ceEllipse:
      begin
        nn := E.Extrusion;
        // minor axis = extrusion x major axis, scaled by the ratio
        minor := CadVec((nn.Y * E.MajorAxis.Z - nn.Z * E.MajorAxis.Y) * E.Ratio,
          (nn.Z * E.MajorAxis.X - nn.X * E.MajorAxis.Z) * E.Ratio);
        a0 := E.StartParam;
        sw := E.EndParam - E.StartParam;
        while sw <= 1e-12 do sw := sw + 2 * Pi;
        while sw > 2 * Pi + 1e-9 do sw := sw - 2 * Pi;
        P.ArcCenter(0, 0, 1, 1, 0, a0, sw, 1);
        if Abs(sw - 2 * Pi) < 1e-6 then P.Close;
        P.Transform(TXVMatrix.Make(E.MajorAxis.X, E.MajorAxis.Y, minor.X, minor.Y, E.Center.X, E.Center.Y));
      end;
    cePolyline: BulgePath(E.Pts, E.Bulges, E.Closed, P);
    ceSpline: SplinePath(E.Pts, E.Weights, E.Knots, E.Degree, E.FitPts, E.Closed, P);
    ceSolid, ceWipeout:
      if Length(E.Pts) >= 3 then
      begin
        if E.Kind = ceSolid then
        begin
          // corners 1 2 4 3
          q[0] := XVPt(E.Pts[0].X, E.Pts[0].Y); q[1] := XVPt(E.Pts[1].X, E.Pts[1].Y);
          if Length(E.Pts) >= 4 then
          begin
            q[2] := XVPt(E.Pts[3].X, E.Pts[3].Y); q[3] := XVPt(E.Pts[2].X, E.Pts[2].Y);
            P.AddPolygon(q, True);
          end
          else
          begin
            q[2] := XVPt(E.Pts[2].X, E.Pts[2].Y);
            P.AddPolygon(Slice(q, 3), True);
          end;
        end
        else
        begin
          for i := 0 to High(E.Pts) do
            if i = 0 then P.MoveTo(E.Pts[i].X, E.Pts[i].Y) else P.LineTo(E.Pts[i].X, E.Pts[i].Y);
          P.Close;
        end;
        P.Transform(M);
        if E.Kind = ceWipeout then Doc.AddPath(P, XVSolid(XV_WHITE), XVNoStroke)
        else Doc.AddPath(P, XVSolid(col), XVNoStroke);
        Exit;
      end;
    ceFace:
      begin
        for i := 0 to Min(3, High(E.Pts)) do
          if i = 0 then P.MoveTo(E.Pts[i].X, E.Pts[i].Y) else P.LineTo(E.Pts[i].X, E.Pts[i].Y);
        P.Close;
      end;
    ceHatch: begin Hatch(E, Ctx, M, col); Exit; end;
    ceText: begin Text(E, Ctx, M, col); Exit; end;
    ceMText: begin MText(E, Ctx, M, col); Exit; end;
    ceInsert, ceDimension: begin Insert(E, Ctx, li); Exit; end;
    ceImage: begin Image(E, Ctx, col); Exit; end;
  end;
  if P.NCmd = 0 then Exit;
  P.Transform(M);
  st := MakeStroke(E, Ctx, li, M);
  // wide closed polylines and donuts are outlines with width
  fill := False;
  if fill then ;
  Doc.AddPath(P, XVNoPaint, st, frNonZero);
end;

procedure TCadConv.Ents(const L: TCadEntities; const Ctx: TCadCtx);
var i: Integer;
begin
  for i := 0 to High(L) do
    try
      Entity(L[i], Ctx);
    except
      // a malformed entity is skipped
    end;
end;

// an image file named by the drawing: as given, next to the drawing, or its
// name alone next to the drawing
function TCadConv.ImageIndex(const FileName: string): Integer;
var
  k: Integer;
  fn, cand, path: string;
  img: TXVImage;
begin
  Result := -1;
  if FileName = '' then Exit;
  k := ImageNames.IndexOf(FileName);
  if k >= 0 then Exit(ImageIdx[k]);
  fn := StringReplace(StringReplace(FileName, '\', PathDelim, [rfReplaceAll]), '/', PathDelim, [rfReplaceAll]);
  path := '';
  for k := 0 to 2 do
  begin
    case k of
      0: cand := fn;
      1: if Cad.BaseDir <> '' then cand := IncludeTrailingPathDelimiter(Cad.BaseDir) + fn else cand := '';
    else
      if Cad.BaseDir <> '' then cand := IncludeTrailingPathDelimiter(Cad.BaseDir) + ExtractFileName(fn) else cand := '';
    end;
    if (cand <> '') and FileExists(cand) then
    begin
      path := cand;
      Break;
    end;
  end;
  if (path <> '') and XVDecodeImage(XVReadFileBytes(path), img) then Result := Doc.AddImageData(img);
  ImageNames.Add(FileName);
  SetLength(ImageIdx, ImageNames.Count);
  ImageIdx[High(ImageIdx)] := Result;
end;

// a raster image, clipped by its boundary; a frame when the file is missing
procedure TCadConv.Image(const E: TCadEntity; const Ctx: TCadCtx; C: TXVColor);
var
  w, h: Double;
  ins: TCadVec;
  P: TXVPath;
  i, idx: Integer;
  m: TXVMatrix;
  a, b: TCadVec;

  // entity pixel space (y down, 0..w x 0..h) -> document
  function World(X, Y: Double): TXVPoint;
  begin
    Result := Ctx.M.Apply(ins.X + X * E.UVec.X + (h - Y) * E.VVec.X, ins.Y + X * E.UVec.Y + (h - Y) * E.VVec.Y);
  end;

  procedure Pt(X, Y: Double; First: Boolean);
  var q: TXVPoint;
  begin
    q := World(X, Y);
    if First then P.MoveTo(q.X, q.Y) else P.LineTo(q.X, q.Y);
  end;

begin
  if Length(E.Pts) = 0 then Exit;
  ins := E.Pts[0];
  w := E.ImageSize.X;
  h := E.ImageSize.Y;
  if (w <= 0) or (h <= 0) then Exit;
  P := Default(TXVPath);
  P.Clear;
  if E.ClipOn and (Length(E.ClipPts) = 2) then
  begin
    // a rectangle by two corners; clip coordinates start at -0.5
    a := E.ClipPts[0];
    b := E.ClipPts[1];
    Pt(a.X + 0.5, a.Y + 0.5, True); Pt(b.X + 0.5, a.Y + 0.5, False);
    Pt(b.X + 0.5, b.Y + 0.5, False); Pt(a.X + 0.5, b.Y + 0.5, False);
    P.Close;
  end
  else if E.ClipOn and (Length(E.ClipPts) > 2) then
  begin
    for i := 0 to High(E.ClipPts) do Pt(E.ClipPts[i].X + 0.5, E.ClipPts[i].Y + 0.5, i = 0);
    P.Close;
  end
  else
  begin
    Pt(0, 0, True); Pt(w, 0, False); Pt(w, h, False); Pt(0, h, False);
    P.Close;
  end;
  idx := ImageIndex(E.ImageFile);
  if idx < 0 then
  begin
    Doc.AddPath(P, XVNoPaint, XVStroke(C, 0));
    Exit;
  end;
  // the image's pixels onto the entity's pixel grid
  m := TXVMatrix.Make(E.UVec.X, E.UVec.Y, -E.VVec.X, -E.VVec.Y, ins.X + h * E.VVec.X, ins.Y + h * E.VVec.Y);
  m := XVMul(Ctx.M, XVMul(m, TXVMatrix.Scale(w / Doc.Images[idx].W, h / Doc.Images[idx].H)));
  if E.ClipOn then
  begin
    Doc.BeginGroup(Doc.AddClip(P), 1);
    Doc.AddImage(idx, m, 1);
    Doc.EndGroup;
  end
  else Doc.AddImage(idx, m, 1);
end;

procedure XVCadToDocument(Cad: TCadDrawing; Doc: TXVDocument);
var
  conv: TCadConv;
  ctx: TCadCtx;
  r: TXVRect;
  s, w, h, pxPerUnit: Double;
  i: Integer;
begin
  Cad.BuildIndex;
  if GetEnvironmentVariable('XV_CADDEBUG') <> '' then
  begin
    WriteLn(StdErr, 'model space: ', Length(Cad.Ents));
    for i := 0 to High(Cad.Blocks) do
      WriteLn(StdErr, 'block ', Cad.Blocks[i].Name, ': ', Length(Cad.Blocks[i].Ents), ' at ', Cad.FindBlock(Cad.Blocks[i].Name));
  end;
  conv := TCadConv.Create;
  try
    conv.Cad := Cad;
    conv.Doc := Doc;
    conv.ImageNames := TStringList.Create;
    case Cad.InsUnits of
      1: conv.UnitMM := 25.4;
      2: conv.UnitMM := 304.8;
      4: conv.UnitMM := 1;
      5: conv.UnitMM := 10;
      6: conv.UnitMM := 1000;
      8: conv.UnitMM := 0.0000254;
      9: conv.UnitMM := 0.0254;
      10: conv.UnitMM := 914.4;
      14: conv.UnitMM := 100;
    else
      conv.UnitMM := 0;
    end;
    ctx.M := TXVMatrix.Identity;
    ctx.Color := XV_BLACK;
    ctx.LType := '';
    ctx.LWeight := -3;
    ctx.Layer := '';
    ctx.Depth := 0;
    conv.Ents(Cad.Ents, ctx);
  finally
    conv.ImageNames.Free;
    conv.Free;
  end;
  // CAD y points up: flip into document space around the drawing's box
  if not Doc.ContentBounds(r) then
  begin
    Doc.SetPageSize(100, 100);
    Exit;
  end;
  w := Max(r.Width, 1e-9);
  h := Max(r.Height, 1e-9);
  if Cad.InsUnits in [1, 4, 5] then
  begin
    case Cad.InsUnits of
      1: pxPerUnit := 96;
      4: pxPerUnit := 96 / 25.4;
    else
      pxPerUnit := 96 / 2.54;
    end;
    if (Max(w, h) * pxPerUnit < 64) or (Max(w, h) * pxPerUnit > 8000) then pxPerUnit := 1000 / Max(w, h);
  end
  else pxPerUnit := 1000 / Max(w, h);
  s := 1;
  Doc.Transform(TXVMatrix.Make(s, 0, 0, -s, -r.Left * s, r.Bottom * s));
  Doc.ViewBox := XVRect(0, 0, w * s, h * s);
  Doc.Width := w * pxPerUnit;
  Doc.Height := h * pxPerUnit;
  Doc.Background := XV_WHITE;
end;

end.
