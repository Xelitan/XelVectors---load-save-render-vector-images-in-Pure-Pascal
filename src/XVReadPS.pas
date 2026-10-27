unit XVReadPS;

{$mode delphi}{$H+}
{$R-}{$Q-}

// XelVectors - PostScript and Encapsulated PostScript reader.
//
// A PostScript interpreter (language level 2 with the common level 3
// additions): the scanner (strings, hex and ASCII85 strings, procedures,
// immediately evaluated names), operand / dictionary stacks, the control,
// type, dictionary, string, array and file operators (filters ASCIIHex,
// ASCII85, RunLength, Flate, LZW, DCT, SubFile; eexec), the graphics state
// (CTM, paths, clipping, dashes, colour spaces with Indexed, Separation and
// DeviceN, patterns and shadings), painting (fill, stroke, shfill, images)
// and text (findfont / scalefont / makefont, the show family, Type 3 fonts
// through BuildGlyph / BuildChar, encodings). What is painted becomes the
// document; one page is kept (Doc.LoadPage). EPS files take their size from
// %%BoundingBox, DOS EPS binaries are unwrapped.

interface

uses
  SysUtils, Classes, Math, Generics.Collections, XVModel, XVImageCodec, XelInflate;

function XVIsPS(const Data: TBytes): Boolean;
procedure XVReadPSDoc(Doc: TXVDocument; const Data: TBytes);

implementation

type
  EPSError = class(Exception)
  public
    ErrName: string;
  end;
  EPSExit = class(Exception);
  EPSStop = class(Exception);
  EPSQuit = class(Exception);

  TPSKind = (okNull, okInt, okReal, okBool, okName, okString, okArray, okDict, okOp, okMark, okFile, okSave);

  TPSString = class;
  TPSArray = class;
  TPSDict = class;
  TPSFile = class;

  TPSObj = record
    K: TPSKind;
    X: Boolean;                    // executable
    I: Int64;                      // integer, boolean, operator index, save level
    R: Double;
    N: string;                     // name
    S: TPSString;                  // string storage
    A: TPSArray;                   // array storage
    Off, Len: Integer;             // interval of a string / array
    D: TPSDict;
    F: TPSFile;
  end;
  PPSObj = ^TPSObj;

  TPSString = class
    Data: TBytes;
  end;

  TPSArray = class
    Items: array of TPSObj;
  end;

  TPSDict = class
    Map: TDictionary<string, TPSObj>;
    Keys: TDictionary<string, TPSObj>;      // the original key objects
    MaxLen: Integer;
    constructor Create;
    destructor Destroy; override;
  end;

  TPSFile = class
    Data: TBytes;
    Pos: Integer;
    Closed: Boolean;
    Parent: TPSFile;               // eexec: the file the encrypted part came from
    ParentResume: Integer;
  end;

  TPSClip = record
    Path: TXVPath;
    Rule: TXVFillRule;
  end;

  TPSColorSpace = (csGray, csRGB, csCMYK, csIndexed, csPattern, csSeparation, csDeviceN, csLab);

  TPSGState = record
    CTM: TXVMatrix;
    Path: TXVPath;                 // device space
    CS: TPSColorSpace;
    CSObj: TPSObj;                 // the colour space array
    Comps: array[0..7] of Double;
    NComps: Integer;
    Color: TXVColor;
    PatternPaint: Integer;         // gradient index of a shading pattern, -1
    PatternTile: Integer;          // tiling pattern (Tiles index), -1
    LineWidth: Double;
    Cap: TXVLineCap;
    Join: TXVLineJoin;
    Miter: Double;
    Dash: TXVDoubles;
    DashOfs: Double;
    Font: TPSObj;
    Clips: array of TPSClip;
    ClipSerial: Integer;
    Flat: Double;
  end;

  // a tiling pattern: its cell drawn once, in pattern space
  TPSTile = record
    Cell: TXVDocument;
    M: TXVMatrix;                  // pattern space -> device
    XStep, YStep: Double;
    BBox: TXVRect;
    Uncoloured: Boolean;
  end;

  // a glyph outline in glyph space and its advance
  TPSGlyph = record
    Path: TXVPath;
    Width: Double;
    Ok: Boolean;
  end;

  // the TrueType data of a Type 42 font
  TPSTrueType = class
    Data: TBytes;
    Ok, LongLoca: Boolean;
    UnitsPerEm, Loca, Glyf, Hmtx, NumHMetrics, NumGlyphs: Integer;
  end;

  TOpProc = procedure(Code: Integer) of object;

  TOpRec = record
    Name: string;
    Proc: TOpProc;
    Code: Integer;
  end;

  { TPSInterp }

  TPSInterp = class
  private
    Doc: TXVDocument;
    Objs: TList;                   // everything allocated, freed at the end
    Ops: array of TOpRec;
    OS: array of TPSObj;
    OSN: Integer;
    DS: array of TPSDict;
    SysDict, UserDict, GlobalDict, StatusDict, ErrorDict, DError, FontDir, ResDict, InternalDict: TPSDict;
    GS: TPSGState;
    GStack: array of TPSGState;
    SaveLevel: Integer;
    SaveMarks: array of Integer;   // gstate depth at each save
    Files: array of TPSFile;       // currentfile stack
    MainFile: TPSFile;
    Depth: Integer;
    // output
    Page, TargetPage: Integer;
    PageStart: Integer;
    EmittedSerial, OpenGroups, ClipSerialGen: Integer;
    Drew: Boolean;
    PageW, PageH: Double;
    BBoxSet: Boolean;
    BLLX, BLLY, BURX, BURY: Double;
    DefaultCTM: TXVMatrix;
    StdEnc, IsoEnc: TPSObj;
    RandSeed_: Cardinal;
    Steps: Int64;
    Debug, IsEPS, PageSizeSet: Boolean;
    CurCmd: string;
    NPages, Clock, CurOp: Integer;
    Tiles: array of TPSTile;
    GlyphCache: TDictionary<string, TPSGlyph>;
    TTCache: TDictionary<PtrUInt, TPSTrueType>;
    CharFont: TPSDict;           // the Type 3 font of the glyph being built
    // objects
    function NewStr(Len: Integer): TPSObj;
    function StrObj(const S: string): TPSObj;
    function NewArr(Len: Integer): TPSObj;
    function NewDict(Cap: Integer): TPSDict;
    function DictObj(D: TPSDict): TPSObj;
    function NameObj(const S: string; Exec: Boolean): TPSObj;
    function IntObj(V: Int64): TPSObj;
    function RealObj(V: Double): TPSObj;
    function BoolObj(V: Boolean): TPSObj;
    function NullObj: TPSObj;
    function StrOf(const O: TPSObj): string;
    function KeyOf(const O: TPSObj): string;
    function ArrItem(const O: TPSObj; I: Integer): TPSObj;
    procedure ArrSet(const O: TPSObj; I: Integer; const V: TPSObj);
    procedure DictPut(D: TPSDict; const K: string; const V: TPSObj); overload;
    procedure DictPutK(D: TPSDict; const Key, V: TPSObj);
    function DictGet(D: TPSDict; const K: string; out V: TPSObj): Boolean;
    function DictGetDef(D: TPSDict; const K: string): TPSObj;
    // stack
    procedure Err(const Name: string);
    procedure Push(const O: TPSObj);
    function Pop: TPSObj;
    function Top(N: Integer = 0): PPSObj;
    function PopNum: Double;
    function PopInt: Int64;
    function PopBool: Boolean;
    function PopStr: TPSObj;
    function PopArr: TPSObj;
    function PopDict: TPSDict;
    function PopProc: TPSObj;
    function PopMatrix(out M: TXVMatrix): TPSObj;
    function IsNum(const O: TPSObj): Boolean;
    function NumOf(const O: TPSObj): Double;
    function MatrixOf(const O: TPSObj): TXVMatrix;
    procedure SetMatrixObj(const O: TPSObj; const M: TXVMatrix);
    function CountToMark: Integer;
    // execution
    function Lookup(const Name: string; out V: TPSObj): Boolean;
    procedure Exec(const O: TPSObj);
    procedure ExecProc(const O: TPSObj);
    procedure RunFile(F: TPSFile);
    function Token(F: TPSFile; out O: TPSObj): Boolean;
    procedure DSC(const Line: string);
    procedure AddOp(const Name: string; P: TOpProc; Code: Integer);
    procedure Init;
    function DoBind(const O: TPSObj; Lvl: Integer): TPSObj;
    // files
    function CurFile: TPSFile;
    function FileByte(F: TPSFile): Integer;
    function MakeFilter(Src: TPSFile; const Name: string; Params: TPSDict): TPSFile;
    function DecodeEexec(F: TPSFile): TPSFile;
    // graphics
    procedure Emit(Fill: Boolean; Rule: TXVFillRule);
    procedure SyncClip;
    procedure ClosePageGroups;
    function UserToDev(X, Y: Double): TXVPoint;
    function CurPointUser(out X, Y: Double): Boolean;
    procedure SetColorComps(N: Integer);
    function CompsToColor(Space: TPSColorSpace; const C: array of Double; N: Integer; const CSO: TPSObj): TXVColor;
    function SpaceOf(const O: TPSObj; out N: Integer): TPSColorSpace;
    function EvalFunction(const F: TPSObj; T: Double; out Res: TXVDoubles): Boolean;
    function ShadingGradient(const Sh: TPSDict; const M: TXVMatrix; out AvgColor: TXVColor): Integer;
    procedure DoImage(Kind: Integer);
    procedure ShowText(const S: TPSObj; Mode: Integer; AX, AY, CX, CY: Double; CChar: Integer; const Proc: TPSObj;
      const Disp: TPSObj);
    function FontInfo(const F: TPSObj; out Family: string; out Bold, Italic: Boolean; out FM: TXVMatrix): Boolean;
    function GlyphUnicode(const F: TPSObj; Code: Integer): Cardinal;
    function TextWidth(const F: TPSObj; const S: TPSObj): Double;
    procedure ShowPage;
    // operator groups
    procedure OpStack(Code: Integer);
    procedure OpArith(Code: Integer);
    procedure OpRel(Code: Integer);
    procedure OpControl(Code: Integer);
    procedure OpType(Code: Integer);
    procedure OpDict(Code: Integer);
    procedure OpString(Code: Integer);
    procedure OpGState(Code: Integer);
    procedure OpMatrix(Code: Integer);
    procedure OpPath(Code: Integer);
    procedure OpPaint(Code: Integer);
    procedure OpFont(Code: Integer);
    procedure OpFile(Code: Integer);
    procedure OpMisc(Code: Integer);
    procedure OpIgnore(Code: Integer);
    procedure OpPrint(Code: Integer);
    procedure AddOps(const Names: array of string; P: TOpProc);
    procedure GSave;
    procedure GRestore;
    procedure InitGraphics;
    procedure SetPage(LLX, LLY, URX, URY: Double);
    procedure AddClipPath(Rule: TXVFillRule);
    procedure ArcUser(CX, CY, R, A1, A2: Double; CCW: Boolean);
    function CvsText(const O: TPSObj): string;
    function ObjEq(const A, B: TPSObj): Boolean;
    procedure CopyDict(Src, Dst: TPSDict);
    function FindFont(const Key: TPSObj): TPSObj;
    function ScaledFont(const F: TPSObj; const M: TXVMatrix): TPSObj;
    procedure SetError(const Name: string);
    function TempFile(const O: TPSObj): TPSFile;
    function FileObj(F: TPSFile): TPSObj;
    function PopRects: TXVDoubles;
    procedure RectsToPath(const R: TXVDoubles);
    function SubStr(const O: TPSObj; Off, Len: Integer): TPSObj;
    procedure Prescan(const D: TBytes);
    procedure FillTiles(Rule: TXVFillRule);
    function Type1Glyph(FD: TPSDict; const Name: string; out G: TPSGlyph): Boolean;
    function TrueTypeOf(const Sfnts: TPSObj): TPSTrueType;
    function Type42Glyph(FD: TPSDict; const Name: string; out G: TPSGlyph): Boolean;
    function OutlineKind(const F: TPSObj): Integer;
    function GlyphFor(const F: TPSObj; Code: Integer; out G: TPSGlyph): Boolean;
    function RunType3(const GName: TPSObj; Code: Integer; X, Y: Double): Double;
    procedure ShowGlyphName(const Name: string);
    function GlyphByName(const F: TPSObj; const Name: string; out G: TPSGlyph): Boolean;
    procedure ShowOutlines(const S: TPSObj; Mode: Integer; AX, AY, CX, CY: Double; CChar: Integer; const Disp: TPSObj);
  public
    constructor Create(ADoc: TXVDocument);
    destructor Destroy; override;
    procedure Run(const Data: TBytes);
  end;

// ------------------------------ objects ------------------------------------

constructor TPSDict.Create;
begin
  inherited Create;
  Map := TDictionary<string, TPSObj>.Create;
  Keys := TDictionary<string, TPSObj>.Create;
end;

destructor TPSDict.Destroy;
begin
  Map.Free;
  Keys.Free;
  inherited Destroy;
end;

function TPSInterp.NewStr(Len: Integer): TPSObj;
var s: TPSString;
begin
  s := TPSString.Create;
  Objs.Add(s);
  SetLength(s.Data, Max(0, Len));
  if Len > 0 then FillChar(s.Data[0], Len, 0);
  Result := Default(TPSObj);
  Result.K := okString;
  Result.S := s;
  Result.Off := 0;
  Result.Len := Max(0, Len);
end;

function TPSInterp.StrObj(const S: string): TPSObj;
begin
  Result := NewStr(Length(S));
  if S <> '' then Move(S[1], Result.S.Data[0], Length(S));
end;

function TPSInterp.NewArr(Len: Integer): TPSObj;
var a: TPSArray; i: Integer;
begin
  a := TPSArray.Create;
  Objs.Add(a);
  SetLength(a.Items, Max(0, Len));
  for i := 0 to High(a.Items) do a.Items[i] := Default(TPSObj);
  Result := Default(TPSObj);
  Result.K := okArray;
  Result.A := a;
  Result.Off := 0;
  Result.Len := Max(0, Len);
end;

function TPSInterp.NewDict(Cap: Integer): TPSDict;
begin
  Result := TPSDict.Create;
  Result.MaxLen := Cap;
  Objs.Add(Result);
end;

function TPSInterp.DictObj(D: TPSDict): TPSObj;
begin
  Result := Default(TPSObj);
  Result.K := okDict;
  Result.D := D;
end;

function TPSInterp.NameObj(const S: string; Exec: Boolean): TPSObj;
begin
  Result := Default(TPSObj);
  Result.K := okName;
  Result.N := S;
  Result.X := Exec;
end;

function TPSInterp.IntObj(V: Int64): TPSObj;
begin
  Result := Default(TPSObj);
  Result.K := okInt;
  Result.I := V;
end;

function TPSInterp.RealObj(V: Double): TPSObj;
begin
  Result := Default(TPSObj);
  Result.K := okReal;
  if IsNan(V) or IsInfinite(V) then V := 0;
  Result.R := V;
end;

function TPSInterp.BoolObj(V: Boolean): TPSObj;
begin
  Result := Default(TPSObj);
  Result.K := okBool;
  Result.I := Ord(V);
end;

function TPSInterp.NullObj: TPSObj;
begin
  Result := Default(TPSObj);
  Result.K := okNull;
end;

function TPSInterp.StrOf(const O: TPSObj): string;
begin
  Result := '';
  case O.K of
    okString:
      begin
        SetLength(Result, O.Len);
        if O.Len > 0 then Move(O.S.Data[O.Off], Result[1], O.Len);
      end;
    okName: Result := O.N;
  end;
end;

// dictionary keys: names and strings alike, integral reals as integers
function TPSInterp.KeyOf(const O: TPSObj): string;
begin
  case O.K of
    okName: Result := O.N;
    okString: Result := StrOf(O);
    okInt: Result := #1'i' + IntToStr(O.I);
    okReal: if Frac(O.R) = 0 then Result := #1'i' + IntToStr(Trunc(O.R)) else Result := #1'r' + FloatToStr(O.R);
    okBool: Result := #1'b' + IntToStr(O.I);
    okNull: Result := #1'n';
    okDict: Result := #1'd' + IntToHex(PtrUInt(O.D), 16);
    okArray: Result := #1'a' + IntToHex(PtrUInt(O.A), 16) + IntToStr(O.Off);
    okOp: Result := #1'o' + IntToStr(O.I);
  else
    Result := #1'?';
  end;
end;

function TPSInterp.ArrItem(const O: TPSObj; I: Integer): TPSObj;
begin
  if (I < 0) or (I >= O.Len) then Err('rangecheck');
  Result := O.A.Items[O.Off + I];
end;

procedure TPSInterp.ArrSet(const O: TPSObj; I: Integer; const V: TPSObj);
begin
  if (I < 0) or (I >= O.Len) then Err('rangecheck');
  O.A.Items[O.Off + I] := V;
end;

procedure TPSInterp.DictPut(D: TPSDict; const K: string; const V: TPSObj);
begin
  D.Map.AddOrSetValue(K, V);
  D.Keys.AddOrSetValue(K, NameObj(K, False));
end;

procedure TPSInterp.DictPutK(D: TPSDict; const Key, V: TPSObj);
var k: string; ko: TPSObj;
begin
  k := KeyOf(Key);
  D.Map.AddOrSetValue(k, V);
  ko := Key;
  if ko.K = okString then ko := NameObj(StrOf(Key), False);
  D.Keys.AddOrSetValue(k, ko);
end;

function TPSInterp.DictGet(D: TPSDict; const K: string; out V: TPSObj): Boolean;
begin
  Result := (D <> nil) and D.Map.TryGetValue(K, V);
end;

function TPSInterp.DictGetDef(D: TPSDict; const K: string): TPSObj;
begin
  if not DictGet(D, K, Result) then Result := NullObj;
end;

// ------------------------------ stack --------------------------------------

procedure TPSInterp.Err(const Name: string);
var e: EPSError;
begin
  e := EPSError.Create(Name);
  e.ErrName := Name;
  raise e;
end;

procedure TPSInterp.Push(const O: TPSObj);
var tmp: TPSObj;
begin
  if OSN >= Length(OS) then
  begin
    if OSN > 500000 then Err('stackoverflow');
    tmp := O;                      // O may live in the stack itself
    SetLength(OS, Max(256, OSN * 2));
    OS[OSN] := tmp;
    Inc(OSN);
    Exit;
  end;
  OS[OSN] := O;
  Inc(OSN);
end;

function TPSInterp.Pop: TPSObj;
begin
  if OSN <= 0 then Err('stackunderflow');
  Dec(OSN);
  Result := OS[OSN];
  OS[OSN] := Default(TPSObj);
end;

function TPSInterp.Top(N: Integer): PPSObj;
begin
  if OSN - 1 - N < 0 then Err('stackunderflow');
  Result := @OS[OSN - 1 - N];
end;

function TPSInterp.IsNum(const O: TPSObj): Boolean;
begin
  Result := O.K in [okInt, okReal];
end;

function TPSInterp.NumOf(const O: TPSObj): Double;
begin
  case O.K of
    okInt: Result := O.I;
    okReal: Result := O.R;
  else
    begin
      Err('typecheck');
      Result := 0;
    end;
  end;
end;

function TPSInterp.PopNum: Double;
begin
  Result := NumOf(Pop);
end;

function TPSInterp.PopInt: Int64;
var o: TPSObj;
begin
  o := Pop;
  if o.K = okInt then Result := o.I
  else if o.K = okReal then Result := Trunc(o.R)
  else begin Err('typecheck'); Result := 0; end;
end;

function TPSInterp.PopBool: Boolean;
var o: TPSObj;
begin
  o := Pop;
  if o.K <> okBool then Err('typecheck');
  Result := o.I <> 0;
end;

function TPSInterp.PopStr: TPSObj;
begin
  Result := Pop;
  if Result.K = okName then Result := StrObj(Result.N)
  else if Result.K <> okString then Err('typecheck');
end;

function TPSInterp.PopArr: TPSObj;
begin
  Result := Pop;
  if Result.K <> okArray then Err('typecheck');
end;

function TPSInterp.PopDict: TPSDict;
var o: TPSObj;
begin
  o := Pop;
  if o.K <> okDict then Err('typecheck');
  Result := o.D;
end;

function TPSInterp.PopProc: TPSObj;
begin
  Result := Pop;
  if not (Result.K in [okArray, okName, okOp, okString]) then Err('typecheck');
end;

function TPSInterp.MatrixOf(const O: TPSObj): TXVMatrix;
begin
  if (O.K <> okArray) or (O.Len < 6) then Err('typecheck');
  Result := TXVMatrix.Make(NumOf(ArrItem(O, 0)), NumOf(ArrItem(O, 1)), NumOf(ArrItem(O, 2)), NumOf(ArrItem(O, 3)),
    NumOf(ArrItem(O, 4)), NumOf(ArrItem(O, 5)));
end;

procedure TPSInterp.SetMatrixObj(const O: TPSObj; const M: TXVMatrix);
begin
  if (O.K <> okArray) or (O.Len < 6) then Err('typecheck');
  ArrSet(O, 0, RealObj(M.A)); ArrSet(O, 1, RealObj(M.B)); ArrSet(O, 2, RealObj(M.C));
  ArrSet(O, 3, RealObj(M.D)); ArrSet(O, 4, RealObj(M.E)); ArrSet(O, 5, RealObj(M.F));
end;

function TPSInterp.PopMatrix(out M: TXVMatrix): TPSObj;
begin
  Result := PopArr;
  M := MatrixOf(Result);
end;

function TPSInterp.CountToMark: Integer;
var i: Integer;
begin
  for i := OSN - 1 downto 0 do
    if OS[i].K = okMark then Exit(OSN - 1 - i);
  Err('unmatchedmark');
  Result := 0;
end;

// ------------------------------ execution ----------------------------------

function TPSInterp.Lookup(const Name: string; out V: TPSObj): Boolean;
var i: Integer;
begin
  for i := High(DS) downto 0 do
    if DS[i].Map.TryGetValue(Name, V) then Exit(True);
  Result := False;
end;

procedure TPSInterp.Exec(const O: TPSObj);
var v: TPSObj;
begin
  Inc(Steps);
  if Steps > 400000000 then raise EPSQuit.Create('limit');
  case O.K of
    okName:
      if O.X then
      begin
        CurCmd := O.N;
        if not Lookup(O.N, v) then Err('undefined');
        if v.K = okOp then begin CurOp := v.I; Ops[v.I].Proc(Ops[v.I].Code); end
        else if (v.K = okArray) and v.X then ExecProc(v)
        else if v.X and (v.K in [okName, okFile, okString]) then
        begin
          Inc(Depth);
          if Depth > 1500 then begin Dec(Depth); Err('execstackoverflow'); end;
          try Exec(v); finally Dec(Depth); end;
        end
        else Push(v);
      end
      else Push(O);
    okOp: begin CurOp := O.I; Ops[O.I].Proc(Ops[O.I].Code); end;
    okArray: if O.X then ExecProc(O) else Push(O);
    okFile: if O.X then RunFile(O.F) else Push(O);
    okString:
      if O.X then
      begin
        // an executable string: scan and execute it
        v := Default(TPSObj);
        v.K := okFile;
        v.F := TPSFile.Create;
        Objs.Add(v.F);
        SetLength(v.F.Data, O.Len);
        if O.Len > 0 then Move(O.S.Data[O.Off], v.F.Data[0], O.Len);
        RunFile(v.F);
      end
      else Push(O);
  else
    Push(O);
  end;
end;

procedure TPSInterp.ExecProc(const O: TPSObj);
var
  i: Integer;
  e: TPSObj;
begin
  Inc(Depth);
  if Depth > 1500 then begin Dec(Depth); Err('execstackoverflow'); end;
  try
    for i := 0 to O.Len - 1 do
    begin
      e := O.A.Items[O.Off + i];
      // procedures inside procedures are data
      if e.K = okArray then Push(e)
      else if e.X and (e.K in [okName, okOp, okFile]) then Exec(e)
      else Push(e);
    end;
  finally
    Dec(Depth);
  end;
end;

procedure TPSInterp.RunFile(F: TPSFile);
var
  o: TPSObj;
  n: Integer;
begin
  if F = nil then Exit;
  n := Length(Files);
  SetLength(Files, n + 1);
  Files[n] := F;
  try
    while not F.Closed do
    begin
      if not Token(F, o) then Break;
      if o.K = okArray then Push(o)
      else if o.X and (o.K in [okName, okOp]) then Exec(o)
      else Push(o);
    end;
  finally
    SetLength(Files, n);
  end;
end;

function IsDelim(c: Byte): Boolean; inline;
begin
  Result := c in [Ord('('), Ord(')'), Ord('<'), Ord('>'), Ord('['), Ord(']'), Ord('{'), Ord('}'), Ord('/'), Ord('%')];
end;

function IsWhite(c: Byte): Boolean; inline;
begin
  Result := c in [0, 9, 10, 12, 13, 32];
end;

procedure SkipOneWhite(F: TPSFile);
begin
  if (F.Pos < Length(F.Data)) and IsWhite(F.Data[F.Pos]) then
  begin
    if (F.Data[F.Pos] = 13) and (F.Pos + 1 < Length(F.Data)) and (F.Data[F.Pos + 1] = 10) then Inc(F.Pos);
    Inc(F.Pos);
  end;
end;

procedure TPSInterp.DSC(const Line: string);
var
  a: TStringArray;
  t: string;
begin
  if (Copy(Line, 1, 14) = '%%BoundingBox:') and not BBoxSet then
  begin
    t := Trim(Copy(Line, 15, MaxInt));
    if Pos('atend', t) > 0 then Exit;
    a := t.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Length(a) >= 4 then
    begin
      BLLX := XVStrToFloat(a[0]); BLLY := XVStrToFloat(a[1]); BURX := XVStrToFloat(a[2]); BURY := XVStrToFloat(a[3]);
      BBoxSet := (BURX > BLLX) and (BURY > BLLY);
    end;
  end
  else if Copy(Line, 1, 18) = '%%HiResBoundingBox:' then
  begin
    a := Trim(Copy(Line, 20, MaxInt)).Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Length(a) >= 4 then
    begin
      BLLX := XVStrToFloat(a[0]); BLLY := XVStrToFloat(a[1]); BURX := XVStrToFloat(a[2]); BURY := XVStrToFloat(a[3]);
      BBoxSet := (BURX > BLLX) and (BURY > BLLY);
    end;
  end;
end;

// one token of a file
function TPSInterp.Token(F: TPSFile; out O: TPSObj): Boolean;
var
  d: TBytes;
  n, st, depth_, v, h, cnt, k: Integer;
  c: Byte;
  buf: TBytes;
  bn: Integer;
  s: string;
  items: array of TPSObj;
  sub: TPSObj;
  code: Integer;
  r: Double;
  i64: Int64;
  tuple: Cardinal;
  base, ndig: Integer;

  procedure AddB(b: Byte);
  begin
    if bn >= Length(buf) then SetLength(buf, Max(64, bn * 2));
    buf[bn] := b;
    Inc(bn);
  end;

begin
  Result := False;
  O := Default(TPSObj);
  d := F.Data;
  n := Length(d);
  while True do
  begin
    // white space and comments
    while (F.Pos < n) and IsWhite(d[F.Pos]) do Inc(F.Pos);
    if F.Pos >= n then Exit;
    if d[F.Pos] = Ord('%') then
    begin
      st := F.Pos;
      while (F.Pos < n) and not (d[F.Pos] in [10, 13]) do Inc(F.Pos);
      if (F = MainFile) and (st + 1 < n) and (d[st + 1] = Ord('%')) then
      begin
        SetLength(s, F.Pos - st);
        Move(d[st], s[1], F.Pos - st);
        DSC(s);
      end;
      Continue;
    end;
    Break;
  end;
  c := d[F.Pos];
  Result := True;
  case Chr(c) of
    '(':
      begin
        Inc(F.Pos);
        bn := 0;
        depth_ := 1;
        while F.Pos < n do
        begin
          c := d[F.Pos];
          Inc(F.Pos);
          if c = Ord('\') then
          begin
            if F.Pos >= n then Break;
            c := d[F.Pos];
            Inc(F.Pos);
            case Chr(c) of
              'n': AddB(10);
              'r': AddB(13);
              't': AddB(9);
              'b': AddB(8);
              'f': AddB(12);
              '0'..'7':
                begin
                  v := c - Ord('0');
                  k := 1;
                  while (k < 3) and (F.Pos < n) and (d[F.Pos] in [Ord('0')..Ord('7')]) do
                  begin
                    v := v * 8 + d[F.Pos] - Ord('0');
                    Inc(F.Pos);
                    Inc(k);
                  end;
                  AddB(v and $FF);
                end;
              #13: begin if (F.Pos < n) and (d[F.Pos] = 10) then Inc(F.Pos); end;
              #10: ;
            else
              AddB(c);
            end;
          end
          else if c = Ord('(') then begin Inc(depth_); AddB(c); end
          else if c = Ord(')') then
          begin
            Dec(depth_);
            if depth_ = 0 then Break;
            AddB(c);
          end
          else AddB(c);
        end;
        O := NewStr(bn);
        if bn > 0 then Move(buf[0], O.S.Data[0], bn);
      end;
    '<':
      begin
        Inc(F.Pos);
        if (F.Pos < n) and (d[F.Pos] = Ord('<')) then begin Inc(F.Pos); O := NameObj('<<', True); Exit; end;
        bn := 0;
        if (F.Pos < n) and (d[F.Pos] = Ord('~')) then
        begin
          // ASCII85
          Inc(F.Pos);
          tuple := 0; cnt := 0;
          while F.Pos < n do
          begin
            c := d[F.Pos];
            Inc(F.Pos);
            if c = Ord('~') then begin Inc(F.Pos); Break; end;
            if IsWhite(c) then Continue;
            if (c = Ord('z')) and (cnt = 0) then begin AddB(0); AddB(0); AddB(0); AddB(0); Continue; end;
            if (c < 33) or (c > 117) then Continue;
            tuple := tuple * 85 + Cardinal(c - 33);
            Inc(cnt);
            if cnt = 5 then
            begin
              AddB(tuple shr 24); AddB((tuple shr 16) and $FF); AddB((tuple shr 8) and $FF); AddB(tuple and $FF);
              tuple := 0; cnt := 0;
            end;
          end;
          if cnt > 1 then
          begin
            for k := cnt to 4 do tuple := tuple * 85 + 84;
            for k := 0 to cnt - 2 do AddB((tuple shr (24 - 8 * k)) and $FF);
          end;
        end
        else
        begin
          h := -1;
          while F.Pos < n do
          begin
            c := d[F.Pos];
            Inc(F.Pos);
            if c = Ord('>') then Break;
            case Chr(c) of
              '0'..'9': v := c - 48;
              'a'..'f': v := c - 87;
              'A'..'F': v := c - 55;
            else
              Continue;
            end;
            if h < 0 then h := v else begin AddB(h * 16 + v); h := -1; end;
          end;
          if h >= 0 then AddB(h * 16);
        end;
        O := NewStr(bn);
        if bn > 0 then Move(buf[0], O.S.Data[0], bn);
      end;
    '>':
      begin
        Inc(F.Pos);
        if (F.Pos < n) and (d[F.Pos] = Ord('>')) then Inc(F.Pos);
        O := NameObj('>>', True);
      end;
    '[', ']':
      begin
        Inc(F.Pos);
        O := NameObj(Chr(c), True);
      end;
    '{':
      begin
        Inc(F.Pos);
        items := nil;
        while True do
        begin
          while (F.Pos < n) and IsWhite(d[F.Pos]) do Inc(F.Pos);
          if F.Pos >= n then Break;
          if d[F.Pos] = Ord('}') then begin Inc(F.Pos); Break; end;
          if not Token(F, sub) then Break;
          SetLength(items, Length(items) + 1);
          items[High(items)] := sub;
        end;
        O := NewArr(Length(items));
        for k := 0 to High(items) do O.A.Items[k] := items[k];
        O.X := True;
      end;
    '}':
      begin
        Inc(F.Pos);
        Err('syntaxerror');
      end;
    '/':
      begin
        Inc(F.Pos);
        st := F.Pos;
        if (F.Pos < n) and (d[F.Pos] = Ord('/')) then
        begin
          Inc(F.Pos);
          st := F.Pos;
          while (F.Pos < n) and not IsWhite(d[F.Pos]) and not IsDelim(d[F.Pos]) do Inc(F.Pos);
          SetLength(s, F.Pos - st);
          if F.Pos > st then Move(d[st], s[1], F.Pos - st);
          // immediately evaluated name
          if not Lookup(s, O) then Err('undefined');
          Exit;
        end;
        while (F.Pos < n) and not IsWhite(d[F.Pos]) and not IsDelim(d[F.Pos]) do Inc(F.Pos);
        SetLength(s, F.Pos - st);
        if F.Pos > st then Move(d[st], s[1], F.Pos - st);
        O := NameObj(s, False);
        SkipOneWhite(F);
      end;
  else
    begin
      st := F.Pos;
      while (F.Pos < n) and not IsWhite(d[F.Pos]) and not IsDelim(d[F.Pos]) do Inc(F.Pos);
      SetLength(s, F.Pos - st);
      if F.Pos > st then Move(d[st], s[1], F.Pos - st)
      else begin Inc(F.Pos); s := Chr(c); end;
      // the white space character that ends the token is part of it
      SkipOneWhite(F);
      // numbers: integers, reals, radix numbers
      if (s[1] in ['0'..'9', '-', '+', '.']) then
      begin
        if (Pos('.', s) = 0) and (Pos('e', s) = 0) and (Pos('E', s) = 0) and (Pos('#', s) = 0) then
        begin
          Val(s, i64, code);
          if code = 0 then
          begin
            if (i64 > High(Integer)) or (i64 < Low(Integer)) then O := RealObj(i64) else O := IntObj(i64);
            Exit;
          end;
        end;
        if (Pos('#', s) = 0) and (s <> '-') and (s <> '+') and (s <> '.') then
        begin
          if s[1] = '.' then Val('0' + s, r, code)
          else if (Length(s) > 1) and (s[1] in ['-', '+']) and (s[2] = '.') then Val(s[1] + '0' + Copy(s, 2, MaxInt), r, code)
          else Val(s, r, code);
          if code = 0 then begin O := RealObj(r); Exit; end;
        end;
        k := Pos('#', s);
        if k > 1 then
        begin
          base := StrToIntDef(Copy(s, 1, k - 1), 0);
          if (base >= 2) and (base <= 36) then
          begin
            i64 := 0;
            ndig := 0;
            for v := k + 1 to Length(s) do
            begin
              case s[v] of
                '0'..'9': h := Ord(s[v]) - 48;
                'a'..'z': h := Ord(s[v]) - 87;
                'A'..'Z': h := Ord(s[v]) - 55;
              else
                h := 99;
              end;
              if h >= base then begin ndig := -1; Break; end;
              i64 := i64 * base + h;
              Inc(ndig);
            end;
            if ndig > 0 then begin O := IntObj(i64); Exit; end;
          end;
        end;
      end;
      O := NameObj(s, True);
    end;
  end;
end;

// ------------------------------ files --------------------------------------

function TPSInterp.CurFile: TPSFile;
begin
  if Length(Files) > 0 then Result := Files[High(Files)] else Result := MainFile;
end;

function TPSInterp.FileByte(F: TPSFile): Integer;
begin
  if (F = nil) or F.Closed or (F.Pos >= Length(F.Data)) then Exit(-1);
  Result := F.Data[F.Pos];
  Inc(F.Pos);
end;

// eexec: the encrypted rest of the file (hex or binary), decrypted
function TPSInterp.DecodeEexec(F: TPSFile): TPSFile;
var
  p, n, i, k, z, endPos: Integer;
  hex: Boolean;
  raw: TBytes;
  r: Word;
  c, v: Byte;
  h: Integer;
begin
  Result := TPSFile.Create;
  Objs.Add(Result);
  p := F.Pos;
  n := Length(F.Data);
  while (p < n) and IsWhite(F.Data[p]) do Inc(p);
  // the encrypted part ends before a long run of zeros
  endPos := n;
  z := 0;
  for i := p to n - 1 do
  begin
    if F.Data[i] = Ord('0') then
    begin
      Inc(z);
      if z >= 64 then begin endPos := i - z + 1; Break; end;
    end
    else if not IsWhite(F.Data[i]) then z := 0;
  end;
  hex := True;
  for i := p to Min(p + 3, n - 1) do
    if not (Chr(F.Data[i]) in ['0'..'9', 'a'..'f', 'A'..'F']) then hex := False;
  SetLength(raw, endPos - p);
  k := 0;
  if hex then
  begin
    h := -1;
    for i := p to endPos - 1 do
    begin
      case Chr(F.Data[i]) of
        '0'..'9': v := F.Data[i] - 48;
        'a'..'f': v := F.Data[i] - 87;
        'A'..'F': v := F.Data[i] - 55;
      else
        Continue;
      end;
      if h < 0 then h := v else begin raw[k] := h * 16 + v; Inc(k); h := -1; end;
    end;
  end
  else
  begin
    if endPos > p then Move(F.Data[p], raw[0], endPos - p);
    k := endPos - p;
  end;
  SetLength(raw, k);
  r := 55665;
  for i := 0 to k - 1 do
  begin
    c := raw[i];
    raw[i] := c xor (r shr 8);
    r := Word((c + r) * 52845 + 22719);
  end;
  if k > 4 then Result.Data := Copy(raw, 4, k - 4) else Result.Data := nil;
  Result.Parent := F;
  Result.ParentResume := endPos;
  F.Pos := endPos;
end;

function LzwDecode(const Src: TBytes; EarlyChange: Integer; out Used: Integer): TBytes;
var
  dict: array of TBytes;
  bitbuf: Cardinal;
  bits, codeLen, p, n, code, prev, outN: Integer;
  entry: TBytes;
  o: TBytes;

  procedure Put(const B: TBytes);
  begin
    if outN + Length(B) > Length(o) then SetLength(o, Max(outN + Length(B), Length(o) * 2 + 256));
    if Length(B) > 0 then Move(B[0], o[outN], Length(B));
    Inc(outN, Length(B));
  end;

  procedure ResetDict;
  var i: Integer;
  begin
    SetLength(dict, 258);
    for i := 0 to 255 do begin SetLength(dict[i], 1); dict[i][0] := i; end;
    codeLen := 9;
    prev := -1;
  end;

begin
  o := nil; outN := 0;
  ResetDict;
  bitbuf := 0; bits := 0; p := 0; n := Length(Src);
  while True do
  begin
    while (bits < codeLen) and (p < n) do
    begin
      bitbuf := (bitbuf shl 8) or Src[p];
      Inc(p);
      Inc(bits, 8);
    end;
    if bits < codeLen then Break;
    code := (bitbuf shr (bits - codeLen)) and ((1 shl codeLen) - 1);
    Dec(bits, codeLen);
    if code = 256 then begin ResetDict; Continue; end;
    if code = 257 then Break;
    if code < Length(dict) then
    begin
      entry := dict[code];
      if prev >= 0 then
      begin
        SetLength(dict, Length(dict) + 1);
        dict[High(dict)] := Copy(dict[prev]);
        SetLength(dict[High(dict)], Length(dict[prev]) + 1);
        dict[High(dict)][High(dict[High(dict)])] := entry[0];
      end;
    end
    else if prev >= 0 then
    begin
      entry := Copy(dict[prev]);
      SetLength(entry, Length(entry) + 1);
      entry[High(entry)] := dict[prev][0];
      SetLength(dict, Length(dict) + 1);
      dict[High(dict)] := entry;
    end
    else Break;
    Put(entry);
    prev := code;
    if Length(dict) + EarlyChange >= (1 shl codeLen) then
      if codeLen < 12 then Inc(codeLen);
  end;
  SetLength(o, outN);
  Result := o;
  Used := p;
end;

// A filter reads its encoded data from the source up to its end of data and
// becomes a file of the decoded bytes.
function TPSInterp.MakeFilter(Src: TPSFile; const Name: string; Params: TPSDict): TPSFile;
var
  p, n, st, k, cnt, h, v, ln: Integer;
  o: TBytes;
  on_: Integer;
  c: Byte;
  tuple: Cardinal;
  consumed: NativeUInt;
  pv: TPSObj;
  eod: string;
  img: TXVImage;

  procedure AddB(b: Byte);
  begin
    if on_ >= Length(o) then SetLength(o, Max(256, on_ * 2));
    o[on_] := b;
    Inc(on_);
  end;

begin
  Result := TPSFile.Create;
  Objs.Add(Result);
  o := nil; on_ := 0;
  if Src = nil then Exit;
  p := Src.Pos;
  n := Length(Src.Data);
  if (Name = 'ASCIIHexDecode') or (Name = 'AHx') then
  begin
    h := -1;
    while p < n do
    begin
      c := Src.Data[p];
      Inc(p);
      if c = Ord('>') then Break;
      case Chr(c) of
        '0'..'9': v := c - 48;
        'a'..'f': v := c - 87;
        'A'..'F': v := c - 55;
      else
        Continue;
      end;
      if h < 0 then h := v else begin AddB(h * 16 + v); h := -1; end;
    end;
    if h >= 0 then AddB(h * 16);
  end
  else if (Name = 'ASCII85Decode') or (Name = 'A85') then
  begin
    tuple := 0; cnt := 0;
    while p < n do
    begin
      c := Src.Data[p];
      Inc(p);
      if c = Ord('~') then begin if (p < n) and (Src.Data[p] = Ord('>')) then Inc(p); Break; end;
      if IsWhite(c) then Continue;
      if (c = Ord('z')) and (cnt = 0) then begin AddB(0); AddB(0); AddB(0); AddB(0); Continue; end;
      if (c < 33) or (c > 117) then Continue;
      tuple := tuple * 85 + Cardinal(c - 33);
      Inc(cnt);
      if cnt = 5 then
      begin
        AddB(tuple shr 24); AddB((tuple shr 16) and $FF); AddB((tuple shr 8) and $FF); AddB(tuple and $FF);
        tuple := 0; cnt := 0;
      end;
    end;
    if cnt > 1 then
    begin
      for k := cnt to 4 do tuple := tuple * 85 + 84;
      for k := 0 to cnt - 2 do AddB((tuple shr (24 - 8 * k)) and $FF);
    end;
  end
  else if (Name = 'RunLengthDecode') or (Name = 'RL') then
  begin
    while p < n do
    begin
      ln := Src.Data[p];
      Inc(p);
      if ln = 128 then Break;
      if ln < 128 then
      begin
        for k := 0 to ln do if p < n then begin AddB(Src.Data[p]); Inc(p); end;
      end
      else if p < n then
      begin
        for k := 0 to 256 - ln do AddB(Src.Data[p]);
        Inc(p);
      end;
    end;
  end
  else if (Name = 'FlateDecode') or (Name = 'Fl') then
  begin
    try
      o := InflateZlibEx(@Src.Data[p], n - p, consumed);
      on_ := Length(o);
      Inc(p, consumed);
    except
      o := nil; on_ := 0;
      p := n;
    end;
  end
  else if (Name = 'LZWDecode') or (Name = 'LZW') then
  begin
    k := 1;
    if (Params <> nil) and DictGet(Params, 'EarlyChange', pv) then k := Round(NumOf(pv));
    // the encoded data runs to the end of the source (its end code stops it)
    o := LzwDecode(Copy(Src.Data, p, n - p), k, st);
    on_ := Length(o);
    Inc(p, st);
  end
  else if (Name = 'DCTDecode') or (Name = 'DCT') then
  begin
    // the JPEG stream up to its end marker; decoded into raw samples
    st := p;
    while (p + 1 < n) and not ((Src.Data[p] = $FF) and (Src.Data[p + 1] = $D9)) do Inc(p);
    Inc(p, 2);
    // the number of components, from the frame header
    cnt := 3;
    k := st + 2;
    while k + 9 < p do
    begin
      if (Src.Data[k] = $FF) and (Src.Data[k + 1] in [$C0, $C1, $C2]) then
      begin
        cnt := Src.Data[k + 9];
        Break;
      end;
      if Src.Data[k] = $FF then
      begin
        if Src.Data[k + 1] in [$D8, $01, $D0..$D7, $FF] then Inc(k, 2)
        else Inc(k, 2 + (Src.Data[k + 2] shl 8) + Src.Data[k + 3]);
      end
      else Inc(k);
    end;
    if XVDecodeImage(Copy(Src.Data, st, p - st), img) then
    begin
      // samples as "image" expects them: gray, RGB or CMYK
      if not (cnt in [1, 3, 4]) then cnt := 3;
      SetLength(o, img.W * img.H * cnt);
      for k := 0 to img.W * img.H - 1 do
      begin
        h := (img.Px[k] shr 16) and $FF; v := (img.Px[k] shr 8) and $FF; ln := img.Px[k] and $FF;
        case cnt of
          1: o[k] := (h * 30 + v * 59 + ln * 11) div 100;
          3: begin o[3 * k] := h; o[3 * k + 1] := v; o[3 * k + 2] := ln; end;
        else
          begin
            o[4 * k] := 255 - h; o[4 * k + 1] := 255 - v; o[4 * k + 2] := 255 - ln; o[4 * k + 3] := 0;
          end;
        end;
      end;
      on_ := Length(o);
    end;
  end
  else if (Name = 'SubFileDecode') then
  begin
    // count and end of data string
    cnt := 0; eod := '';
    if Params <> nil then
    begin
      if DictGet(Params, 'EODCount', pv) then cnt := Round(NumOf(pv));
      if DictGet(Params, 'EODString', pv) then eod := StrOf(pv);
    end;
    st := p;
    if eod <> '' then
    begin
      while p < n do
      begin
        if (Src.Data[p] = Ord(eod[1])) and (p + Length(eod) <= n) then
        begin
          k := 1;
          while (k <= Length(eod)) and (Src.Data[p + k - 1] = Ord(eod[k])) do Inc(k);
          if k > Length(eod) then
          begin
            if cnt <= 0 then Break;
            Dec(cnt);
          end;
        end;
        Inc(p);
      end;
      SetLength(o, p - st);
      if p > st then Move(Src.Data[st], o[0], p - st);
      on_ := p - st;
      p := Min(n, p + Length(eod));
    end
    else
    begin
      if cnt <= 0 then cnt := n - p;
      cnt := Min(cnt, n - p);
      SetLength(o, cnt);
      if cnt > 0 then Move(Src.Data[p], o[0], cnt);
      on_ := cnt;
      Inc(p, cnt);
    end;
  end
  else if (Name = 'NullEncode') or (Name = 'ASCIIHexEncode') or (Name = 'ASCII85Encode') or (Name = 'RunLengthEncode') or
    (Name = 'FlateEncode') or (Name = 'LZWEncode') or (Name = 'DCTEncode') then
  begin
    // output filters: a sink
  end
  else
  begin
    // unknown: no data
    on_ := 0;
  end;
  Src.Pos := p;
  SetLength(o, on_);
  Result.Data := o;
end;

// ------------------------------ graphics output ----------------------------

function TPSInterp.UserToDev(X, Y: Double): TXVPoint;
begin
  Result := GS.CTM.Apply(X, Y);
end;

function TPSInterp.CurPointUser(out X, Y: Double): Boolean;
var p: TXVPoint;
begin
  Result := GS.Path.HasCurrent;
  if not Result then begin X := 0; Y := 0; Exit; end;
  p := GS.CTM.Invert.Apply(GS.Path.CurrentPoint);
  X := p.X; Y := p.Y;
end;

procedure TPSInterp.ClosePageGroups;
begin
  while OpenGroups > 0 do
  begin
    Doc.EndGroup;
    Dec(OpenGroups);
  end;
  EmittedSerial := -1;
end;

procedure TPSInterp.SyncClip;
var i: Integer;
begin
  if GS.ClipSerial = EmittedSerial then Exit;
  while OpenGroups > 0 do
  begin
    Doc.EndGroup;
    Dec(OpenGroups);
  end;
  EmittedSerial := GS.ClipSerial;
  for i := 0 to High(GS.Clips) do
  begin
    Doc.BeginGroup(Doc.AddClip(GS.Clips[i].Path, GS.Clips[i].Rule), 1);
    Inc(OpenGroups);
  end;
end;

// a fill with a tiling pattern: the cells that cover the path, clipped by it
procedure TPSInterp.FillTiles(Rule: TXVFillRule);
var
  t: TPSTile;
  r: TXVRect;
  inv, cm: TXVMatrix;
  p: TXVPoint;
  x0, y0, x1, y1, xs, ys: Double;
  i, j, i0, i1, j0, j1, k, n0: Integer;
begin
  t := Tiles[GS.PatternTile];
  if not GS.Path.Bounds(r) then Exit;
  inv := t.M.Invert;
  // the path's box in pattern space
  x0 := 1e300; y0 := 1e300; x1 := -1e300; y1 := -1e300;
  for k := 0 to 3 do
  begin
    case k of
      0: p := inv.Apply(r.Left, r.Top);
      1: p := inv.Apply(r.Right, r.Top);
      2: p := inv.Apply(r.Right, r.Bottom);
    else
      p := inv.Apply(r.Left, r.Bottom);
    end;
    x0 := Min(x0, p.X); y0 := Min(y0, p.Y); x1 := Max(x1, p.X); y1 := Max(y1, p.Y);
  end;
  xs := Abs(t.XStep);
  ys := Abs(t.YStep);
  if xs < 1e-9 then xs := Max(t.BBox.Width, 1e-9);
  if ys < 1e-9 then ys := Max(t.BBox.Height, 1e-9);
  i0 := Floor((x0 - t.BBox.Right) / xs);
  i1 := Ceil((x1 - t.BBox.Left) / xs);
  j0 := Floor((y0 - t.BBox.Bottom) / ys);
  j1 := Ceil((y1 - t.BBox.Top) / ys);
  if (t.Cell.Count = 0) or (Int64(i1 - i0 + 1) * (j1 - j0 + 1) > 20000) then
  begin
    // too many cells: the pattern's colour
    Doc.AddPath(GS.Path, XVSolid(GS.Color), XVNoStroke, Rule);
    Drew := True;
    Exit;
  end;
  Doc.BeginGroup(Doc.AddClip(GS.Path, Rule), 1);
  for j := j0 to j1 do
    for i := i0 to i1 do
    begin
      cm := XVMul(t.M, TXVMatrix.Translate(i * xs, j * ys));
      n0 := Doc.Count;
      Doc.AppendDocument(t.Cell, cm);
      if t.Uncoloured then
        // an uncoloured cell is painted in the current colour
        for k := n0 to Doc.Count - 1 do
          with Doc.Elements[k] do
          begin
            if Fill.Kind <> pkNone then Fill := XVSolid(GS.Color);
            if Stroke.Paint.Kind <> pkNone then Stroke.Paint := XVSolid(GS.Color);
          end;
    end;
  Doc.EndGroup;
  Drew := True;
end;

procedure TPSInterp.Emit(Fill: Boolean; Rule: TXVFillRule);
var
  st: TXVStroke;
  sc: Double;
  i: Integer;
  paint: TXVPaint;
begin
  if GS.Path.NCmd = 0 then Exit;
  if Page <> TargetPage then Exit;
  SyncClip;
  if Fill and (GS.PatternTile >= 0) then
  begin
    FillTiles(Rule);
    Exit;
  end;
  if GS.PatternPaint >= 0 then paint := XVGradientPaint(GS.PatternPaint, GS.Color)
  else paint := XVSolid(GS.Color);
  if Fill then Doc.AddPath(GS.Path, paint, XVNoStroke, Rule)
  else
  begin
    sc := GS.CTM.ScaleFactor;
    st := XVStroke(GS.Color, GS.LineWidth * sc);
    if GS.PatternPaint >= 0 then st.Paint := paint;
    // thin lines are drawn one pixel wide
    if GS.LineWidth * sc < 0.25 then st.Width := 0;
    st.Cap := GS.Cap;
    st.Join := GS.Join;
    st.MiterLimit := GS.Miter;
    if Length(GS.Dash) > 0 then
    begin
      SetLength(st.Dashes, Length(GS.Dash));
      for i := 0 to High(GS.Dash) do st.Dashes[i] := GS.Dash[i] * sc;
      if Odd(Length(st.Dashes)) then
      begin
        SetLength(st.Dashes, 2 * Length(GS.Dash));
        for i := 0 to High(GS.Dash) do st.Dashes[Length(GS.Dash) + i] := GS.Dash[i] * sc;
      end;
      st.DashOffset := GS.DashOfs * sc;
    end;
    Doc.AddPath(GS.Path, XVNoPaint, st, frNonZero);
  end;
  Drew := True;
end;

function TPSInterp.SpaceOf(const O: TPSObj; out N: Integer): TPSColorSpace;
var nm: string; base: TPSObj;
begin
  N := 1;
  if O.K = okName then nm := O.N
  else if (O.K = okArray) and (O.Len > 0) then nm := StrOf(ArrItem(O, 0))
  else nm := 'DeviceGray';
  if (nm = 'DeviceGray') or (nm = 'CalGray') or (nm = 'G') then begin N := 1; Result := csGray; end
  else if (nm = 'DeviceRGB') or (nm = 'CalRGB') or (nm = 'RGB') then begin N := 3; Result := csRGB; end
  else if (nm = 'DeviceCMYK') or (nm = 'CMYK') then begin N := 4; Result := csCMYK; end
  else if (nm = 'Indexed') or (nm = 'I') then begin N := 1; Result := csIndexed; end
  else if nm = 'Pattern' then begin N := 1; Result := csPattern; end
  else if nm = 'Separation' then begin N := 1; Result := csSeparation; end
  else if nm = 'DeviceN' then
  begin
    Result := csDeviceN;
    N := 1;
    if (O.K = okArray) and (O.Len > 1) then
    begin
      base := ArrItem(O, 1);
      if base.K = okArray then N := base.Len;
    end;
  end
  else if nm = 'Lab' then begin N := 3; Result := csLab; end
  else if (nm = 'ICCBased') then
  begin
    // the number of components from the stream dictionary, when there
    N := 3; Result := csRGB;
    if (O.K = okArray) and (O.Len > 1) and (ArrItem(O, 1).K = okDict) then
      if DictGet(ArrItem(O, 1).D, 'N', base) then
      begin
        N := Round(NumOf(base));
        if N = 1 then Result := csGray else if N = 4 then Result := csCMYK else Result := csRGB;
      end;
  end
  else if (nm = 'CIEBasedABC') or (nm = 'CIEBasedDEF') then begin N := 3; Result := csRGB; end
  else if (nm = 'CIEBasedA') then begin N := 1; Result := csGray; end
  else begin N := 1; Result := csGray; end;
end;

function TPSInterp.CompsToColor(Space: TPSColorSpace; const C: array of Double; N: Integer; const CSO: TPSObj): TXVColor;
var
  base, lookup, tint: TPSObj;
  bs: TPSColorSpace;
  bn, i, idx, k: Integer;
  bc: array[0..7] of Double;
  save: Integer;
begin
  case Space of
    csGray: Result := XVRGB(EnsureRange(Round(C[0] * 255), 0, 255), EnsureRange(Round(C[0] * 255), 0, 255),
      EnsureRange(Round(C[0] * 255), 0, 255));
    csRGB: Result := XVRGB(EnsureRange(Round(C[0] * 255), 0, 255), EnsureRange(Round(C[1] * 255), 0, 255),
      EnsureRange(Round(C[2] * 255), 0, 255));
    csCMYK: Result := XVCmykToColor(C[0], C[1], C[2], C[3]);
    csLab: Result := XVRGB(EnsureRange(Round(C[0] * 2.55), 0, 255), EnsureRange(Round(C[0] * 2.55), 0, 255),
      EnsureRange(Round(C[0] * 2.55), 0, 255));
    csIndexed:
      begin
        Result := XV_BLACK;
        if (CSO.K <> okArray) or (CSO.Len < 4) then Exit;
        base := ArrItem(CSO, 1);
        bs := SpaceOf(base, bn);
        lookup := ArrItem(CSO, 3);
        idx := EnsureRange(Round(C[0]), 0, 255);
        if lookup.K = okString then
        begin
          for i := 0 to bn - 1 do
            if idx * bn + i < lookup.Len then bc[i] := lookup.S.Data[lookup.Off + idx * bn + i] / 255 else bc[i] := 0;
        end
        else
        begin
          // a procedure: index -> components
          save := OSN;
          Push(IntObj(idx));
          try Exec(lookup); except end;
          for i := bn - 1 downto 0 do
            if OSN > save then bc[i] := NumOf(Pop) else bc[i] := 0;
          OSN := save;
        end;
        Result := CompsToColor(bs, bc, bn, base);
      end;
    csSeparation, csDeviceN:
      begin
        Result := XV_BLACK;
        if (CSO.K <> okArray) or (CSO.Len < 4) then
        begin
          // a tint of black
          Result := XVRGB(Round(255 * (1 - C[0])), Round(255 * (1 - C[0])), Round(255 * (1 - C[0])));
          Exit;
        end;
        base := ArrItem(CSO, 2);
        bs := SpaceOf(base, bn);
        tint := ArrItem(CSO, 3);
        save := OSN;
        for i := 0 to N - 1 do Push(RealObj(C[i]));
        try
          if tint.K = okArray then Exec(tint) else if tint.K = okDict then
          begin
            OSN := save;
            Result := XVRGB(Round(255 * (1 - C[0])), Round(255 * (1 - C[0])), Round(255 * (1 - C[0])));
            Exit;
          end;
        except
        end;
        k := OSN - save;
        for i := bn - 1 downto 0 do
          if OSN > save then bc[i] := NumOf(Pop) else bc[i] := 0;
        OSN := save;
        if k = 0 then
        begin
          Result := XVRGB(Round(255 * (1 - C[0])), Round(255 * (1 - C[0])), Round(255 * (1 - C[0])));
          Exit;
        end;
        Result := CompsToColor(bs, bc, bn, base);
      end;
  else
    Result := XV_BLACK;
  end;
end;

procedure TPSInterp.SetColorComps(N: Integer);
var
  i, bn: Integer;
  c: array[0..7] of Double;
  o, base: TPSObj;
  bs: TPSColorSpace;
begin
  GS.PatternPaint := -1;
  GS.PatternTile := -1;
  if GS.CS = csPattern then
  begin
    // a pattern dictionary (and the components of an uncoloured pattern)
    o := Pop;
    GS.Color := $FF808080;
    if o.K <> okDict then Exit;
    if DictGet(o.D, 'XVColor', base) then GS.Color := TXVColor(base.I);
    if DictGet(o.D, 'XVGradient', base) and (base.I >= 0) and (base.I <= High(Doc.Gradients)) then
      GS.PatternPaint := base.I;
    if DictGet(o.D, 'XVTile', base) and (base.I >= 0) and (base.I <= High(Tiles)) then
      GS.PatternTile := base.I;
    if DictGet(o.D, 'PaintType', base) and (NumOf(base) = 2) and (GS.CSObj.K = okArray) and (GS.CSObj.Len > 1) then
    begin
      // uncoloured: the colour comes in the underlying space
      base := ArrItem(GS.CSObj, 1);
      bs := SpaceOf(base, bn);
      bn := Min(bn, 8);
      for i := bn - 1 downto 0 do c[i] := PopNum;
      GS.Color := CompsToColor(bs, c, bn, base);
    end;
    Exit;
  end;
  N := Min(N, 8);
  for i := N - 1 downto 0 do c[i] := PopNum;
  for i := 0 to N - 1 do GS.Comps[i] := c[i];
  GS.NComps := N;
  GS.Color := CompsToColor(GS.CS, c, N, GS.CSObj);
end;

// ------------------------------ functions / shadings -----------------------

function TPSInterp.EvalFunction(const F: TPSObj; T: Double; out Res: TXVDoubles): Boolean;
var
  ft, i, k, n, nOut: Integer;
  o, c0, c1, fns, bounds, enc, dom, rng, size, dec: TPSObj;
  e, d0, d1, t0, t1, x: Double;
  sub: TXVDoubles;
  bps, idx, save: Integer;
  data: TPSObj;
  maxv: Double;
begin
  Result := False;
  Res := nil;
  if F.K = okArray then
  begin
    if F.X then
    begin
      // a PostScript calculator procedure
      save := OSN;
      Push(RealObj(T));
      try Exec(F); except end;
      n := OSN - save;
      SetLength(Res, Max(0, n));
      for i := n - 1 downto 0 do Res[i] := NumOf(Pop);
      OSN := save;
      Exit(n > 0);
    end;
    // an array of functions, one per component
    SetLength(Res, F.Len);
    for i := 0 to F.Len - 1 do
      if EvalFunction(ArrItem(F, i), T, sub) and (Length(sub) > 0) then Res[i] := sub[0];
    Exit(True);
  end;
  if F.K <> okDict then Exit;
  if not DictGet(F.D, 'FunctionType', o) then
  begin
    // a dictionary with a procedure
    Exit(False);
  end;
  ft := Round(NumOf(o));
  if DictGet(F.D, 'Domain', dom) and (dom.K = okArray) and (dom.Len >= 2) then
  begin
    d0 := NumOf(ArrItem(dom, 0)); d1 := NumOf(ArrItem(dom, 1));
    T := EnsureRange(T, Min(d0, d1), Max(d0, d1));
  end
  else begin d0 := 0; d1 := 1; end;
  case ft of
    2:
      begin
        e := 1;
        if DictGet(F.D, 'N', o) then e := NumOf(o);
        if not DictGet(F.D, 'C0', c0) then c0 := Default(TPSObj);
        if not DictGet(F.D, 'C1', c1) then c1 := Default(TPSObj);
        if c1.K = okArray then n := c1.Len else n := 1;
        SetLength(Res, n);
        x := Power(Max(T, 0), e);
        for i := 0 to n - 1 do
        begin
          if (c0.K = okArray) and (i < c0.Len) then t0 := NumOf(ArrItem(c0, i)) else t0 := 0;
          if (c1.K = okArray) and (i < c1.Len) then t1 := NumOf(ArrItem(c1, i)) else t1 := 1;
          Res[i] := t0 + x * (t1 - t0);
        end;
        Result := True;
      end;
    3:
      begin
        if not (DictGet(F.D, 'Functions', fns) and (fns.K = okArray) and (fns.Len > 0)) then Exit;
        DictGet(F.D, 'Bounds', bounds);
        DictGet(F.D, 'Encode', enc);
        k := 0;
        while (bounds.K = okArray) and (k < bounds.Len) and (T >= NumOf(ArrItem(bounds, k))) do Inc(k);
        if k >= fns.Len then k := fns.Len - 1;
        if k = 0 then t0 := d0 else t0 := NumOf(ArrItem(bounds, k - 1));
        if k >= bounds.Len then t1 := d1 else t1 := NumOf(ArrItem(bounds, k));
        if (enc.K = okArray) and (enc.Len >= 2 * k + 2) then
        begin
          if t1 > t0 then x := NumOf(ArrItem(enc, 2 * k)) + (T - t0) / (t1 - t0) *
            (NumOf(ArrItem(enc, 2 * k + 1)) - NumOf(ArrItem(enc, 2 * k)))
          else x := NumOf(ArrItem(enc, 2 * k));
        end
        else x := T;
        Result := EvalFunction(ArrItem(fns, k), x, Res);
      end;
    0:
      begin
        // sampled: linear interpolation of a 1-D table
        if not (DictGet(F.D, 'Size', size) and DictGet(F.D, 'DataSource', data) and DictGet(F.D, 'Range', rng)) then Exit;
        bps := 8;
        if DictGet(F.D, 'BitsPerSample', o) then bps := Round(NumOf(o));
        nOut := rng.Len div 2;
        n := Round(NumOf(ArrItem(size, 0)));
        if (n < 1) or (nOut < 1) or (data.K <> okString) then Exit;
        maxv := Power(2, bps) - 1;
        idx := EnsureRange(Round((T - d0) / Max(d1 - d0, 1e-12) * (n - 1)), 0, n - 1);
        SetLength(Res, nOut);
        for i := 0 to nOut - 1 do
        begin
          k := (idx * nOut + i) * (bps div 8);
          if (bps >= 8) and (k < data.Len) then x := data.S.Data[data.Off + k] / 255 * maxv / maxv
          else x := 0;
          if bps = 16 then x := ((data.S.Data[data.Off + k] shl 8) or data.S.Data[data.Off + k + 1]) / 65535;
          if DictGet(F.D, 'Decode', dec) and (dec.Len >= 2 * i + 2) then
            Res[i] := NumOf(ArrItem(dec, 2 * i)) + x * (NumOf(ArrItem(dec, 2 * i + 1)) - NumOf(ArrItem(dec, 2 * i)))
          else
            Res[i] := NumOf(ArrItem(rng, 2 * i)) + x * (NumOf(ArrItem(rng, 2 * i + 1)) - NumOf(ArrItem(rng, 2 * i)));
        end;
        Result := True;
      end;
    4:
      if DictGet(F.D, 'XVProc', o) then Result := EvalFunction(o, T, Res);
  end;
end;

// axial / radial shadings as gradients (other types: their middle colour)
function TPSInterp.ShadingGradient(const Sh: TPSDict; const M: TXVMatrix; out AvgColor: TXVColor): Integer;
var
  st, n, i, k, nsteps: Integer;
  o, coords, fn, cso, dom: TPSObj;
  cs: TPSColorSpace;
  g: TXVGradient;
  t0, t1, t: Double;
  res: TXVDoubles;
  c: array[0..7] of Double;
  r0, r1: Double;
begin
  Result := -1;
  AvgColor := $FF808080;
  if not DictGet(Sh, 'ShadingType', o) then Exit;
  st := Round(NumOf(o));
  if not DictGet(Sh, 'ColorSpace', cso) then cso := NameObj('DeviceRGB', False);
  cs := SpaceOf(cso, n);
  if not DictGet(Sh, 'Function', fn) then fn := Default(TPSObj);
  t0 := 0; t1 := 1;
  if DictGet(Sh, 'Domain', dom) and (dom.K = okArray) and (dom.Len >= 2) then
  begin
    t0 := NumOf(ArrItem(dom, 0)); t1 := NumOf(ArrItem(dom, 1));
  end;
  g := Default(TXVGradient);
  g.Matrix := M;
  g.Spread := spPad;
  if not DictGet(Sh, 'Coords', coords) or (coords.K <> okArray) then
  begin
    // function based and mesh shadings: one colour
    if (fn.K <> okNull) and EvalFunction(fn, (t0 + t1) / 2, res) then
    begin
      for i := 0 to Min(High(res), 7) do c[i] := res[i];
      AvgColor := CompsToColor(cs, c, n, cso);
    end;
    Exit;
  end;
  if (st = 2) and (coords.Len >= 4) then
  begin
    g.Kind := gkLinear;
    g.X1 := NumOf(ArrItem(coords, 0)); g.Y1 := NumOf(ArrItem(coords, 1));
    g.X2 := NumOf(ArrItem(coords, 2)); g.Y2 := NumOf(ArrItem(coords, 3));
    r0 := 0; r1 := 1;
  end
  else if (st = 3) and (coords.Len >= 6) then
  begin
    g.Kind := gkRadial;
    g.FX := NumOf(ArrItem(coords, 0)); g.FY := NumOf(ArrItem(coords, 1)); r0 := NumOf(ArrItem(coords, 2));
    g.CX := NumOf(ArrItem(coords, 3)); g.CY := NumOf(ArrItem(coords, 4)); r1 := NumOf(ArrItem(coords, 5));
    g.R := Max(r1, 1e-9);
    if r0 > r1 then
    begin
      // the large circle first: swap and reverse the parameter
      g.R := r0; g.CX := g.FX; g.CY := g.FY; g.FX := NumOf(ArrItem(coords, 3)); g.FY := NumOf(ArrItem(coords, 4));
      t := t0; t0 := t1; t1 := t;
      t := r0; r0 := r1; r1 := t;
    end;
  end
  else Exit;
  nsteps := 16;
  SetLength(g.Stops, nsteps + 1);
  for k := 0 to nsteps do
  begin
    t := t0 + (t1 - t0) * k / nsteps;
    for i := 0 to 7 do c[i] := 0;
    if EvalFunction(fn, t, res) then
      for i := 0 to Min(High(res), 7) do c[i] := res[i];
    g.Stops[k].Color := CompsToColor(cs, c, n, cso);
    // radial with an inner radius: the parameter starts there
    if (g.Kind = gkRadial) and (r1 > 0) then g.Stops[k].Offset := (r0 + (r1 - r0) * k / nsteps) / r1
    else g.Stops[k].Offset := k / nsteps;
  end;
  AvgColor := g.Stops[nsteps div 2].Color;
  Result := Doc.AddGradient(g);
end;

// ------------------------------ text ---------------------------------------

const
  ISO_NAMES: array[160..255] of string = (
    'space', 'exclamdown', 'cent', 'sterling', 'currency', 'yen', 'brokenbar', 'section', 'dieresis', 'copyright',
    'ordfeminine', 'guillemotleft', 'logicalnot', 'hyphen', 'registered', 'macron', 'degree', 'plusminus',
    'twosuperior', 'threesuperior', 'acute', 'mu', 'paragraph', 'periodcentered', 'cedilla', 'onesuperior',
    'ordmasculine', 'guillemotright', 'onequarter', 'onehalf', 'threequarters', 'questiondown', 'Agrave', 'Aacute',
    'Acircumflex', 'Atilde', 'Adieresis', 'Aring', 'AE', 'Ccedilla', 'Egrave', 'Eacute', 'Ecircumflex', 'Edieresis',
    'Igrave', 'Iacute', 'Icircumflex', 'Idieresis', 'Eth', 'Ntilde', 'Ograve', 'Oacute', 'Ocircumflex', 'Otilde',
    'Odieresis', 'multiply', 'Oslash', 'Ugrave', 'Uacute', 'Ucircumflex', 'Udieresis', 'Yacute', 'Thorn',
    'germandbls', 'agrave', 'aacute', 'acircumflex', 'atilde', 'adieresis', 'aring', 'ae', 'ccedilla', 'egrave',
    'eacute', 'ecircumflex', 'edieresis', 'igrave', 'iacute', 'icircumflex', 'idieresis', 'eth', 'ntilde', 'ograve',
    'oacute', 'ocircumflex', 'otilde', 'odieresis', 'divide', 'oslash', 'ugrave', 'uacute', 'ucircumflex',
    'udieresis', 'yacute', 'thorn', 'ydieresis');
  ASCII_NAMES: array[32..126] of string = (
    'space', 'exclam', 'quotedbl', 'numbersign', 'dollar', 'percent', 'ampersand', 'quoteright', 'parenleft',
    'parenright', 'asterisk', 'plus', 'comma', 'hyphen', 'period', 'slash', 'zero', 'one', 'two', 'three', 'four',
    'five', 'six', 'seven', 'eight', 'nine', 'colon', 'semicolon', 'less', 'equal', 'greater', 'question', 'at',
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V',
    'W', 'X', 'Y', 'Z', 'bracketleft', 'backslash', 'bracketright', 'asciicircum', 'underscore', 'quoteleft',
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v',
    'w', 'x', 'y', 'z', 'braceleft', 'bar', 'braceright', 'asciitilde');

  STD_HIGH: array[0..53] of record C: Byte; N: string; end = (
    (C: 161; N: 'exclamdown'), (C: 162; N: 'cent'), (C: 163; N: 'sterling'), (C: 164; N: 'fraction'),
    (C: 165; N: 'yen'), (C: 166; N: 'florin'), (C: 167; N: 'section'), (C: 168; N: 'currency'),
    (C: 169; N: 'quotesingle'), (C: 170; N: 'quotedblleft'), (C: 171; N: 'guillemotleft'), (C: 172; N: 'guilsinglleft'),
    (C: 173; N: 'guilsinglright'), (C: 174; N: 'fi'), (C: 175; N: 'fl'), (C: 177; N: 'endash'), (C: 178; N: 'dagger'),
    (C: 179; N: 'daggerdbl'), (C: 180; N: 'periodcentered'), (C: 182; N: 'paragraph'), (C: 183; N: 'bullet'),
    (C: 184; N: 'quotesinglbase'), (C: 185; N: 'quotedblbase'), (C: 186; N: 'quotedblright'),
    (C: 187; N: 'guillemotright'), (C: 188; N: 'ellipsis'), (C: 189; N: 'perthousand'), (C: 191; N: 'questiondown'),
    (C: 193; N: 'grave'), (C: 194; N: 'acute'), (C: 195; N: 'circumflex'), (C: 196; N: 'tilde'), (C: 197; N: 'macron'),
    (C: 198; N: 'breve'), (C: 199; N: 'dotaccent'), (C: 200; N: 'dieresis'), (C: 202; N: 'ring'), (C: 203; N: 'cedilla'),
    (C: 205; N: 'hungarumlaut'), (C: 206; N: 'ogonek'), (C: 207; N: 'caron'), (C: 208; N: 'emdash'), (C: 225; N: 'AE'),
    (C: 227; N: 'ordfeminine'), (C: 232; N: 'Lslash'), (C: 233; N: 'Oslash'), (C: 234; N: 'OE'),
    (C: 235; N: 'ordmasculine'), (C: 241; N: 'ae'), (C: 245; N: 'dotlessi'), (C: 248; N: 'lslash'), (C: 249; N: 'oslash'),
    (C: 250; N: 'oe'), (C: 251; N: 'germandbls'));

  EXTRA_GLYPHS: array[0..47] of record N: string; U: Word; end = (
    (N: 'quoteright'; U: $2019), (N: 'quoteleft'; U: $2018), (N: 'quotesingle'; U: $27), (N: 'quotedblleft'; U: $201C),
    (N: 'quotedblright'; U: $201D), (N: 'quotesinglbase'; U: $201A), (N: 'quotedblbase'; U: $201E),
    (N: 'guilsinglleft'; U: $2039), (N: 'guilsinglright'; U: $203A), (N: 'endash'; U: $2013), (N: 'emdash'; U: $2014),
    (N: 'bullet'; U: $2022), (N: 'ellipsis'; U: $2026), (N: 'dagger'; U: $2020), (N: 'daggerdbl'; U: $2021),
    (N: 'perthousand'; U: $2030), (N: 'fraction'; U: $2044), (N: 'florin'; U: $192), (N: 'fi'; U: $FB01),
    (N: 'fl'; U: $FB02), (N: 'OE'; U: $152), (N: 'oe'; U: $153), (N: 'Lslash'; U: $141), (N: 'lslash'; U: $142),
    (N: 'dotlessi'; U: $131), (N: 'Euro'; U: $20AC), (N: 'trademark'; U: $2122), (N: 'minus'; U: $2212),
    (N: 'Aogonek'; U: $104), (N: 'aogonek'; U: $105), (N: 'Cacute'; U: $106), (N: 'cacute'; U: $107),
    (N: 'Eogonek'; U: $118), (N: 'eogonek'; U: $119), (N: 'Nacute'; U: $143), (N: 'nacute'; U: $144),
    (N: 'Sacute'; U: $15A), (N: 'sacute'; U: $15B), (N: 'Zacute'; U: $179), (N: 'zacute'; U: $17A),
    (N: 'Zdotaccent'; U: $17B), (N: 'zdotaccent'; U: $17C), (N: 'Scaron'; U: $160), (N: 'scaron'; U: $161),
    (N: 'Zcaron'; U: $17D), (N: 'zcaron'; U: $17E), (N: 'Ydieresis'; U: $178), (N: 'circumflex'; U: $2C6));

function GlyphNameToUnicode(const N: string): Cardinal;
var i: Integer;
begin
  if N = '' then Exit(0);
  for i := 32 to 126 do if ASCII_NAMES[i] = N then Exit(i);
  for i := 0 to High(EXTRA_GLYPHS) do if EXTRA_GLYPHS[i].N = N then Exit(EXTRA_GLYPHS[i].U);
  for i := 160 to 255 do if ISO_NAMES[i] = N then Exit(i);
  if (Length(N) = 7) and (Copy(N, 1, 3) = 'uni') then Exit(StrToIntDef('$' + Copy(N, 4, 4), 0));
  if (Length(N) >= 5) and (N[1] = 'u') and (N[2] in ['0'..'9', 'A'..'F']) then Exit(StrToIntDef('$' + Copy(N, 2, 6), 0));
  if N = 'tilde' then Exit($2DC);
  Result := 0;
end;

function TPSInterp.GlyphUnicode(const F: TPSObj; Code: Integer): Cardinal;
var enc, g: TPSObj;
begin
  Result := Code;
  if (F.K = okDict) and DictGet(F.D, 'Encoding', enc) and (enc.K = okArray) and (Code < enc.Len) then
  begin
    g := ArrItem(enc, Code);
    if g.K = okName then
    begin
      if (g.N = '.notdef') then Exit(Code);
      Result := GlyphNameToUnicode(g.N);
      if Result = 0 then Result := Code;
    end;
  end;
end;

function TPSInterp.FontInfo(const F: TPSObj; out Family: string; out Bold, Italic: Boolean; out FM: TXVMatrix): Boolean;
var
  o: TPSObj;
  nm, l: string;
begin
  Result := F.K = okDict;
  Family := 'Arial'; Bold := False; Italic := False;
  FM := TXVMatrix.Make(0.001, 0, 0, 0.001, 0, 0);
  if not Result then Exit;
  if DictGet(F.D, 'FontMatrix', o) and (o.K = okArray) and (o.Len >= 6) then FM := MatrixOf(o);
  nm := '';
  if DictGet(F.D, 'FontName', o) then nm := StrOf(o);
  if (Pos('+', nm) = 7) then Delete(nm, 1, 7);        // subset prefix
  l := LowerCase(nm);
  Bold := (Pos('bold', l) > 0) or (Pos('black', l) > 0) or (Pos('heavy', l) > 0) or (Pos('demi', l) > 0) or (Pos('semibold', l) > 0);
  Italic := (Pos('italic', l) > 0) or (Pos('oblique', l) > 0);
  if (Pos('helvetica', l) > 0) or (Pos('arial', l) > 0) or (l = '') then Family := 'Arial'
  else if (Pos('times', l) > 0) then Family := 'Times New Roman'
  else if (Pos('courier', l) > 0) then Family := 'Courier New'
  else if (Pos('symbol', l) > 0) then Family := 'Symbol'
  else if (Pos('zapfdingbats', l) > 0) then Family := 'Wingdings'
  else if Pos('palatino', l) > 0 then Family := 'Palatino Linotype'
  else if Pos('bookman', l) > 0 then Family := 'Bookman Old Style'
  else if Pos('avantgarde', l) > 0 then Family := 'Century Gothic'
  else if Pos('newcenturyschlbk', l) > 0 then Family := 'Century Schoolbook'
  else
  begin
    Family := nm;
    if Pos('-', Family) > 0 then Family := Copy(Family, 1, Pos('-', Family) - 1);
    if (Length(Family) > 2) and (Copy(Family, Length(Family) - 1, 2) = 'MT') then SetLength(Family, Length(Family) - 2);
    if (Length(Family) > 2) and (Copy(Family, Length(Family) - 1, 2) = 'PS') then SetLength(Family, Length(Family) - 2);
  end;
end;

function TPSInterp.TextWidth(const F: TPSObj; const S: TPSObj): Double;
var
  g: TPSGlyph;
  fam, t: string;
  b, it: Boolean;
  fm: TXVMatrix;
  font: TXVFont;
  i: Integer;
  o, w: TPSObj;
  glyph: string;
begin
  FontInfo(F, fam, b, it, fm);
  if OutlineKind(F) > 0 then
  begin
    // widths of the font's own glyphs (glyph space)
    Result := 0;
    font := XVDefaultFont;
    font.Size := 1000;
    for i := 0 to S.Len - 1 do
      if GlyphFor(F, S.S.Data[S.Off + i], g) then Result := Result + g.Width
      else Result := Result + XVEstimateTextWidth(font, XVUtf8OfCode(GlyphUnicode(F, S.S.Data[S.Off + i]))) / 1000 /
        Max(1e-9, Abs(fm.A));
    Exit;
  end;
  // explicit widths (Type 3 and synthetic fonts)
  if (F.K = okDict) and DictGet(F.D, 'Metrics', o) and (o.K = okDict) then ;
  font := XVDefaultFont;
  font.Family := fam;
  font.Size := 1000;
  if b then font.Weight := 700;
  t := '';
  for i := 0 to S.Len - 1 do t := t + XVUtf8OfCode(GlyphUnicode(F, S.S.Data[S.Off + i]));
  Result := XVEstimateTextWidth(font, t);
  if (F.K = okDict) and DictGet(F.D, 'XVWidths', w) and (w.K = okDict) then
  begin
    Result := 0;
    for i := 0 to S.Len - 1 do
    begin
      glyph := IntToStr(S.S.Data[S.Off + i]);
      if DictGet(w.D, #1'i' + glyph, o) then Result := Result + NumOf(o) else Result := Result + 500;
    end;
  end;
end;

// the show family. Mode: 0 show, 1 ashow, 2 widthshow, 3 awidthshow,
// 4 kshow, 5 xshow, 6 yshow, 7 xyshow, 8 cshow (as show), 9 charpath
// one glyph of a Type 3 font at (X, Y), by name or code; its width
function TPSInterp.RunType3(const GName: TPSObj; Code: Integer; X, Y: Double): Double;
var
  fd, saveChar: TPSDict;
  bg, bc, enc, wd, gn: TPSObj;
  fm: TXVMatrix;
  fam: string;
  b, it: Boolean;
  k: Integer;
begin
  Result := 0;
  fd := GS.Font.D;
  FontInfo(GS.Font, fam, b, it, fm);
  if not DictGet(fd, 'Encoding', enc) or (enc.K <> okArray) then enc := NullObj;
  gn := GName;
  if (gn.K = okNull) and (enc.K = okArray) and (Code >= 0) and (Code < enc.Len) then gn := ArrItem(enc, Code);
  if gn.K = okNull then gn := NameObj('.notdef', False);
  if (GName.K <> okNull) and not DictGet(fd, 'BuildGlyph', bg) then
  begin
    // BuildChar takes a code: the glyph name's place in the encoding
    Code := -1;
    if enc.K = okArray then
      for k := 0 to enc.Len - 1 do
        if StrOf(ArrItem(enc, k)) = StrOf(GName) then
        begin
          Code := k;
          Break;
        end;
    if Code < 0 then Exit;
  end;
  fd.Map.Remove('XVLastWidth');
  saveChar := CharFont;
  CharFont := fd;
  GSave;
  try
    GS.CTM := XVMul(GS.CTM, XVMul(TXVMatrix.Translate(X, Y), fm));
    GS.Path.Clear;
    Push(GS.Font);
    try
      if DictGet(fd, 'BuildGlyph', bg) then
      begin
        Push(gn);
        Exec(bg);
      end
      else if DictGet(fd, 'BuildChar', bc) then
      begin
        Push(IntObj(Code));
        Exec(bc);
      end;
    except
      on EPSError do ;
    end;
  finally
    GRestore;
    CharFont := saveChar;
  end;
  if DictGet(fd, 'XVLastWidth', wd) then Result := NumOf(wd);
end;

// glyphshow: a glyph by its name
procedure TPSInterp.ShowGlyphName(const Name: string);
var
  fam: string;
  bold, ital: Boolean;
  fm: TXVMatrix;
  x, y, w: Double;
  o: TPSObj;
  ft: Integer;
  g: TPSGlyph;
  savePath: TXVPath;
  p: TXVPoint;
  font: TXVFont;
  u: Cardinal;
  tm: TXVMatrix;
begin
  if GS.Font.K <> okDict then Err('invalidfont');
  if not CurPointUser(x, y) then Err('nocurrentpoint');
  FontInfo(GS.Font, fam, bold, ital, fm);
  ft := 1;
  if DictGet(GS.Font.D, 'FontType', o) and IsNum(o) then ft := Round(NumOf(o));
  if ft = 3 then w := RunType3(NameObj(Name, False), -1, x, y)
  else if (OutlineKind(GS.Font) > 0) and GlyphByName(GS.Font, Name, g) then
  begin
    if g.Path.NCmd > 0 then
    begin
      savePath := GS.Path;
      GS.Path := g.Path.Copy;
      GS.Path.Transform(XVMul(GS.CTM, XVMul(TXVMatrix.Translate(x, y), fm)));
      Emit(True, frNonZero);
      GS.Path := savePath;
    end;
    w := g.Width;
  end
  else
  begin
    // a system font
    u := GlyphNameToUnicode(Name);
    font := XVDefaultFont;
    font.Family := fam;
    font.Size := 1000;
    if bold then font.Weight := 700;
    font.Italic := ital;
    w := XVEstimateTextWidth(font, XVUtf8OfCode(u)) / 1000 / Max(1e-9, Abs(fm.A));
    if (u > 32) and (Page = TargetPage) then
    begin
      font.Size := 1;
      tm := XVMul(GS.CTM, XVMul(TXVMatrix.Translate(x, y), XVMul(fm, TXVMatrix.Scale(1 / Max(1e-9, Abs(fm.A)), -1 / Max(1e-9, Abs(fm.A))))));
      SyncClip;
      Doc.AddText(XVUtf8OfCode(u), font, tm, XVSolid(GS.Color));
      Drew := True;
    end;
  end;
  p := fm.ApplyVec(w, 0);
  p := UserToDev(x + p.X, y + p.Y);
  GS.Path.MoveTo(p.X, p.Y);
end;

procedure TPSInterp.ShowText(const S: TPSObj; Mode: Integer; AX, AY, CX, CY: Double; CChar: Integer; const Proc: TPSObj;
  const Disp: TPSObj);
var
  fam, t: string;
  bold, ital: Boolean;
  fm, m, tm, glyphM: TXVMatrix;
  font: TXVFont;
  x, y, w, dx, dy, adv, wv: Double;
  i, n, ft, idx, code: Integer;
  o, bc, bg, enc, gname, wd: TPSObj;
  cx_: TXVDoubles;
  p: TXVPoint;
  fd, saveChar: TPSDict;
  perChar: Boolean;
begin
  if (GS.Font.K <> okDict) then Err('invalidfont');
  if not CurPointUser(x, y) then Err('nocurrentpoint');
  FontInfo(GS.Font, fam, bold, ital, fm);
  ft := 1;
  if DictGet(GS.Font.D, 'FontType', o) then ft := Round(NumOf(o));
  n := S.Len;
  if (ft = 3) and (DictGet(GS.Font.D, 'BuildGlyph', bg) or DictGet(GS.Font.D, 'BuildChar', bc)) then
  begin
    // Type 3: the glyph procedures draw each character
    fd := GS.Font.D;
    for i := 0 to n - 1 do
    begin
      code := S.S.Data[S.Off + i];
      p := fm.ApplyVec(RunType3(NullObj, code, x, y), 0);
      x := x + p.X + AX; y := y + p.Y + AY;
      if (Mode in [2, 3]) and (code = CChar) then begin x := x + CX; y := y + CY; end;
      if (Mode in [5, 7]) and (Disp.K = okArray) then
      begin
        // explicit displacements replace the widths
        x := x - p.X - AX; y := y - p.Y - AY;
        if Mode = 5 then begin if i < Disp.Len then x := x + NumOf(ArrItem(Disp, i)); end
        else if 2 * i + 1 < Disp.Len then
        begin
          x := x + NumOf(ArrItem(Disp, 2 * i));
          y := y + NumOf(ArrItem(Disp, 2 * i + 1));
        end;
      end;
    end;
    p := UserToDev(x, y);
    GS.Path.MoveTo(p.X, p.Y);
    Exit;
  end;
  if OutlineKind(GS.Font) > 0 then
  begin
    // the font's own outlines
    ShowOutlines(S, Mode, AX, AY, CX, CY, CChar, Disp);
    Exit;
  end;
  font := XVDefaultFont;
  font.Family := fam;
  font.Size := 1;
  if bold then font.Weight := 700;
  font.Italic := ital;
  t := '';
  for i := 0 to n - 1 do t := t + XVUtf8OfCode(GlyphUnicode(GS.Font, S.S.Data[S.Off + i]));
  // text space: em = 1, y down, at the current point
  glyphM := XVMul(fm, TXVMatrix.Scale(1000, -1000));
  tm := XVMul(GS.CTM, XVMul(TXVMatrix.Translate(x, y), glyphM));
  w := TextWidth(GS.Font, S) / 1000;
  cx_ := nil;
  perChar := (Mode in [1, 2, 3]) or ((Mode in [5, 7]) and (Disp.K = okArray));
  if perChar and (n > 0) then
  begin
    // the position of every character
    SetLength(cx_, n);
    m := glyphM.Invert;
    adv := 0;
    for i := 0 to n - 1 do
    begin
      cx_[i] := adv;
      if Mode in [5, 7] then
      begin
        dx := 0; dy := 0;
        if Mode = 5 then begin if i < Disp.Len then dx := NumOf(ArrItem(Disp, i)); end
        else if 2 * i + 1 < Disp.Len then
        begin
          dx := NumOf(ArrItem(Disp, 2 * i));
          dy := NumOf(ArrItem(Disp, 2 * i + 1));
        end;
        // displacements are in user space
        adv := adv + m.ApplyVec(dx, dy).X;
      end
      else
      begin
        font.Size := 1000;
        wv := XVEstimateTextWidth(font, XVUtf8OfCode(GlyphUnicode(GS.Font, S.S.Data[S.Off + i]))) / 1000;
        font.Size := 1;
        adv := adv + wv;
        if Mode in [1, 3] then adv := adv + m.ApplyVec(AX, AY).X;
        if (Mode in [2, 3]) and (S.S.Data[S.Off + i] = CChar) then adv := adv + m.ApplyVec(CX, CY).X;
      end;
    end;
    w := adv;
  end;
  if (Page = TargetPage) and (Trim(t) <> '') then
  begin
    SyncClip;
    idx := Doc.AddText(t, font, tm, XVSolid(GS.Color));
    if (idx >= 0) and (cx_ <> nil) then Doc.Elements[idx].CharX := cx_;
    Drew := True;
  end;
  // the current point moves by the advance
  p := tm.Apply(w, 0);
  GS.Path.MoveTo(p.X, p.Y);
  if Proc.K = okArray then ;
end;

// ------------------------------ images -------------------------------------

// Kind: 0 image, 1 imagemask, 2 colorimage
procedure TPSInterp.DoImage(Kind: Integer);
var
  w, h, bpc, ncomp, x, y, i, k: Integer;
  m: TXVMatrix;
  dict: TPSDict;
  srcs: array of TPSObj;
  multi, polarity: Boolean;
  data: array of TBytes;
  got: array of Integer;
  img: TXVImage;
  o, dec: TPSObj;
  decode: array[0..15] of Double;
  c: array[0..7] of Double;
  v, maxv: Double;
  s: Integer;
  cs: TPSColorSpace;
  ncs: Integer;
  csobj: TPSObj;

  procedure Fetch(Src: Integer; Need_: Integer);
  var r, save: Integer; f: TPSFile; o2: TPSObj;
  begin
    while got[Src] < Need_ do
    begin
      o2 := srcs[Src];
      if o2.K = okString then
      begin
        // a string is used over and over
        if o2.Len = 0 then Break;
        if Length(data[Src]) < got[Src] + o2.Len then SetLength(data[Src], Max(Need_, got[Src] + o2.Len));
        Move(o2.S.Data[o2.Off], data[Src][got[Src]], Min(o2.Len, Length(data[Src]) - got[Src]));
        Inc(got[Src], o2.Len);
      end
      else if o2.K = okFile then
      begin
        f := o2.F;
        r := Min(Need_ - got[Src], Length(f.Data) - f.Pos);
        if r <= 0 then Break;
        if Length(data[Src]) < got[Src] + r then SetLength(data[Src], got[Src] + r);
        Move(f.Data[f.Pos], data[Src][got[Src]], r);
        Inc(f.Pos, r);
        Inc(got[Src], r);
      end
      else if o2.K = okArray then
      begin
        save := OSN;
        Exec(o2);
        if OSN <= save then Break;
        o2 := Pop;
        OSN := save;
        if (o2.K <> okString) or (o2.Len = 0) then Break;
        if Length(data[Src]) < got[Src] + o2.Len then SetLength(data[Src], Max(Need_, got[Src] + o2.Len));
        Move(o2.S.Data[o2.Off], data[Src][got[Src]], o2.Len);
        Inc(got[Src], o2.Len);
      end
      else Break;
    end;
  end;

  function Sample(Src, Index: Integer): Cardinal;
  var byteI, sh: Integer;
  begin
    // Index: sample number within the source
    Result := 0;
    case bpc of
      8: if Index < got[Src] then Result := data[Src][Index];
      16: if 2 * Index + 1 < got[Src] then Result := (data[Src][2 * Index] shl 8) or data[Src][2 * Index + 1];
    else
      begin
        byteI := (Index * bpc) div 8;
        sh := 8 - bpc - (Index * bpc) mod 8;
        if byteI < got[Src] then Result := (data[Src][byteI] shr sh) and ((1 shl bpc) - 1);
      end;
    end;
  end;

var
  rowBits, rowBytes, sIdx: Integer;
begin
  dict := nil;
  srcs := nil;
  multi := False;
  polarity := False;
  cs := GS.CS; csobj := GS.CSObj;
  ncs := 1;
  for i := 0 to 15 do if Odd(i) then decode[i] := 1 else decode[i] := 0;
  if (OSN > 0) and (Top^.K = okDict) then
  begin
    // level 2 dictionary form
    dict := PopDict;
    w := 0; h := 0; bpc := 8;
    if DictGet(dict, 'Width', o) then w := Round(NumOf(o));
    if DictGet(dict, 'Height', o) then h := Round(NumOf(o));
    if DictGet(dict, 'BitsPerComponent', o) then bpc := Round(NumOf(o));
    if DictGet(dict, 'ImageMatrix', o) then m := MatrixOf(o) else m := TXVMatrix.Make(w, 0, 0, -h, 0, h);
    if DictGet(dict, 'MultipleDataSources', o) then multi := o.I <> 0;
    if not DictGet(dict, 'DataSource', o) then Err('undefined');
    if Kind = 1 then begin ncomp := 1; bpc := 1; end
    else
    begin
      cs := SpaceOf(csobj, ncs);
      ncomp := ncs;
    end;
    if multi and (o.K = okArray) and not o.X then
    begin
      SetLength(srcs, o.Len);
      for i := 0 to o.Len - 1 do srcs[i] := ArrItem(o, i);
    end
    else
    begin
      SetLength(srcs, 1);
      srcs[0] := o;
    end;
    if DictGet(dict, 'Decode', dec) and (dec.K = okArray) then
      for i := 0 to Min(dec.Len, 16) - 1 do decode[i] := NumOf(ArrItem(dec, i));
    if Kind = 1 then polarity := decode[0] = 1;
  end
  else
  begin
    if Kind = 2 then
    begin
      ncomp := PopInt;
      multi := PopBool;
      if multi then
      begin
        SetLength(srcs, ncomp);
        for i := ncomp - 1 downto 0 do srcs[i] := Pop;
      end
      else
      begin
        SetLength(srcs, 1);
        srcs[0] := Pop;
      end;
    end
    else
    begin
      SetLength(srcs, 1);
      srcs[0] := Pop;
      ncomp := 1;
    end;
    m := MatrixOf(PopArr);
    if Kind = 1 then
    begin
      polarity := PopBool;
      bpc := 1;
    end
    else bpc := PopInt;
    h := PopInt;
    w := PopInt;
    if Kind = 0 then begin cs := csGray; ncs := 1; end
    else if Kind = 2 then
    begin
      if ncomp = 4 then cs := csCMYK else if ncomp = 3 then cs := csRGB else cs := csGray;
      ncs := ncomp;
    end;
  end;
  if (w <= 0) or (h <= 0) or (Int64(w) * h > 50000000) then Exit;
  if not (bpc in [1, 2, 4, 8, 12, 16]) then bpc := 8;
  if cs = csIndexed then
    for i := 0 to 1 do decode[i] := i * (Power(2, bpc) - 1);
  SetLength(data, Length(srcs));
  SetLength(got, Length(srcs));
  rowBits := w * bpc;
  if Length(srcs) = 1 then rowBits := rowBits * ncomp;
  rowBytes := (rowBits + 7) div 8;
  for s := 0 to High(srcs) do
  begin
    got[s] := 0;
    Fetch(s, rowBytes * h);
  end;
  img := XVNewImage(w, h);
  maxv := Power(2, bpc) - 1;
  for y := 0 to h - 1 do
    for x := 0 to w - 1 do
    begin
      if Kind = 1 then
      begin
        // stencil: painted where the sample equals the polarity... 1 bits paint with polarity true
        sIdx := y * rowBytes * 8 + x;
        k := 0;
        if (sIdx div 8) < got[0] then k := (data[0][sIdx div 8] shr (7 - sIdx mod 8)) and 1;
        if (k = 1) = polarity then img.Px[y * w + x] := GS.Color else img.Px[y * w + x] := 0;
        Continue;
      end;
      for i := 0 to ncomp - 1 do
      begin
        if Length(srcs) = 1 then
        begin
          if bpc >= 8 then sIdx := (y * rowBytes * 8 div bpc) + x * ncomp + i
          else sIdx := ((y * rowBytes * 8) div bpc) + x * ncomp + i;
          v := Sample(0, sIdx);
        end
        else v := Sample(i, (y * ((w * bpc + 7) div 8) * 8) div bpc + x);
        c[i] := decode[2 * i] + v / maxv * (decode[2 * i + 1] - decode[2 * i]);
      end;
      if cs = csIndexed then c[0] := decode[0] + v * (decode[1] - decode[0]) / maxv;
      img.Px[y * w + x] := CompsToColor(cs, c, ncomp, csobj);
    end;
  if (Page = TargetPage) then
  begin
    SyncClip;
    Doc.AddImage(Doc.AddImageData(img), XVMul(GS.CTM, m.Invert), 1);
    Drew := True;
  end;
end;

// ------------------------------ pages --------------------------------------

procedure TPSInterp.ShowPage;
begin
  ClosePageGroups;
  if Page = TargetPage then
  begin
    if Drew then raise EPSQuit.Create('page done');
    // an empty page counts as the requested one only if nothing comes after
  end
  else
    Doc.Truncate(PageStart);
  Inc(Page);
  PageStart := Doc.Count;
  Drew := False;
end;

{$I XVPSFonts.inc}
{$I XVPSOps.inc}

// ------------------------------ entry points -------------------------------

function XVIsPS(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) > 4) and (((Data[0] = Ord('%')) and (Data[1] = Ord('!'))) or
    ((Data[0] = $C5) and (Data[1] = $D0) and (Data[2] = $D3) and (Data[3] = $C6)) or
    ((Data[0] = $04) and (Data[1] = Ord('%')) and (Data[2] = Ord('!'))));
end;

procedure XVReadPSDoc(Doc: TXVDocument; const Data: TBytes);
var R: TPSInterp;
begin
  R := TPSInterp.Create(Doc);
  try
    R.Run(Data);
  finally
    R.Free;
  end;
end;

initialization
  XVRegisterReader('PS', 'ps;eps;epsf;epsi', XVIsPS, XVReadPSDoc);
end.
