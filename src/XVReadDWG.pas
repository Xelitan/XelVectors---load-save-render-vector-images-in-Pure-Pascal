unit XVReadDWG;

{$mode delphi}{$H+}
{$R-}{$Q-}

// XelVectors - AutoCAD DWG reader (R13, R14, R2000, R2004, R2007, R2010,
// R2013, R2018).
//
// The file containers: R13-R2000 (section locators, objects at file
// offsets), R2004 and later (encrypted header, page and section maps, pages
// compressed with the DWG LZ77 variant) and R2007 (Reed-Solomon interleaved
// pages, R21 compression). Inside them the classes and the object map are
// read, then every object of the bit-coded object stream: the tables
// (block headers, layers, linetypes, text styles) and the drawable entities.
// R2007 and later keep the strings of an object in a separate string stream
// and every version keeps the handle references in a handle stream at the
// end of the object. The result is a TCadDrawing (the DXF reader's model),
// drawn by XVCadToDocument.

interface

uses
  SysUtils, Classes, Math, Generics.Collections, XVModel, XVCadModel;

function XVIsDWG(const Data: TBytes): Boolean;
procedure XVReadDWGDoc(Doc: TXVDocument; const Data: TBytes);

implementation

const
  R13 = 12; R14 = 14; R2000 = 15; R2004 = 18; R2007 = 21; R2010 = 24; R2013 = 27; R2018 = 32;

type
  EDwgError = class(Exception);

  { TBits: a bit cursor over a byte range }

  TBits = record
    D: TBytes;
    Base: Integer;                 // byte offset of bit 0
    Limit: Int64;                  // number of bits
    Pos: Int64;                    // bit position from Base
    Ver: Integer;
    CodePage: Integer;
    Bad: Boolean;
    procedure Init(const AData: TBytes; ABase, ASize, AVer: Integer);
    function ReadB: Integer;
    function ReadBB: Integer;
    function ReadRC: Byte;
    function ReadRS: Word;
    function ReadRL: Cardinal;
    function ReadRD: Double;
    function ReadBS: Integer;
    function ReadBL: Integer;
    function ReadBLL: Int64;
    function ReadBD: Double;
    function ReadDD(Def: Double): Double;
    function ReadMC: Int64;
    function ReadUMC: Int64;
    function ReadMS: Int64;
    function ReadH(out Code: Integer): Int64;
    function ReadHRef(Ref: Int64): Int64;
    function ReadOT: Integer;
    function Read2RD: TCadVec;
    function Read2BD: TCadVec;
    function Read3BD: TCadVec;
    function ReadBE: TCadVec;
    function ReadBT: Double;
    function ReadTV: string;
    function ReadTU: string;
    procedure Skip(Bits: Int64);
  end;

  TDwgClass = record
    Num: Integer;
    DxfName: string;
    IsEntity: Boolean;
  end;

  TDwgSection = record
    Name: string;
    Data: TBytes;
  end;

  TDwgMapEntry = record
    Handle, Offset: Int64;
  end;

  // an entity as read, before names are resolved
  TDwgEnt = record
    Ent: TCadEntity;
    Typ: Integer;                  // DWG type (variable types mapped to 77 / 78 / ...)
    Handle, Owner: Int64;
    EntMode: Integer;
    LayerH, LTypeH, StyleH, BlockH: Int64;
    LTFlags: Integer;
    Flags: Integer;                // polylines: closed / 3D flags
    ImageDefH: Int64;
  end;

  TDwgBlockRec = record
    Name: string;
    Base: TCadVec;
  end;

  { TDwgReader }

  TDwgReader = class
  private
    Data: TBytes;
    Ver, Maint, CodePage: Integer;
    Debug: Boolean;
    Sections: array of TDwgSection;
    ObjBuf: TBytes;
    Classes: array of TDwgClass;
    Map: array of TDwgMapEntry;
    Ents: array of TDwgEnt;
    NEnts: Integer;
    BlockRecs: TDictionary<Int64, TDwgBlockRec>;
    LayerIdx: TDictionary<Int64, Integer>;
    LTypeNames, StyleNames: TDictionary<Int64, string>;
    LayerLTypeH: TDictionary<Int64, Int64>;
    ImageDefs: TDictionary<Int64, string>;
    procedure Log(const S: string);
    function SectionData(const Name: string; out Buf: TBytes): Boolean;
    // containers
    procedure ReadR2000;
    procedure ReadR2004;
    procedure ReadR2007;
    // contents
    procedure ReadClasses(const Buf: TBytes; Ofs, Len: Integer);
    procedure ReadObjectMap(const Buf: TBytes; Ofs, Len: Integer);
    procedure ReadObjects;
    procedure ReadObject(const Ent: TDwgMapEntry);
    function ClassOf(Typ: Integer; out C: TDwgClass): Boolean;
    procedure Assemble;
  public
    Cad: TCadDrawing;
    constructor Create;
    destructor Destroy; override;
    procedure Run(const AData: TBytes);
  end;

// ------------------------------ bit cursor ---------------------------------

procedure TBits.Init(const AData: TBytes; ABase, ASize, AVer: Integer);
begin
  D := AData;
  Base := ABase;
  if ABase + ASize > Length(AData) then ASize := Max(0, Length(AData) - ABase);
  Limit := Int64(ASize) * 8;
  Pos := 0;
  Ver := AVer;
  Bad := False;
  CodePage := 1252;
end;

procedure TBits.Skip(Bits: Int64);
begin
  Inc(Pos, Bits);
  if Pos > Limit then Bad := True;
end;

function TBits.ReadB: Integer;
begin
  if (Pos < 0) or (Pos >= Limit) then
  begin
    Bad := True;
    Inc(Pos);
    Exit(0);
  end;
  Result := (D[Base + (Pos shr 3)] shr (7 - (Pos and 7))) and 1;
  Inc(Pos);
end;

function TBits.ReadBB: Integer;
begin
  Result := ReadB shl 1;
  Result := Result or ReadB;
end;

function TBits.ReadRC: Byte;
var
  i: Int64;
  sh: Integer;
begin
  if (Pos < 0) or (Pos + 8 > Limit) then
  begin
    Bad := True;
    Inc(Pos, 8);
    Exit(0);
  end;
  i := Base + (Pos shr 3);
  sh := Pos and 7;
  if sh = 0 then Result := D[i]
  else Result := Byte((D[i] shl sh) or (D[i + 1] shr (8 - sh)));
  Inc(Pos, 8);
end;

function TBits.ReadRS: Word;
begin
  Result := ReadRC;
  Result := Result or (Word(ReadRC) shl 8);
end;

function TBits.ReadRL: Cardinal;
begin
  Result := ReadRS;
  Result := Result or (Cardinal(ReadRS) shl 16);
end;

function TBits.ReadRD: Double;
var
  b: array[0..7] of Byte;
  i: Integer;
begin
  for i := 0 to 7 do b[i] := ReadRC;
  Move(b[0], Result, 8);
  if IsNan(Result) or IsInfinite(Result) then Result := 0;
end;

function TBits.ReadBS: Integer;
begin
  case ReadBB of
    0: Result := SmallInt(ReadRS);
    1: Result := ReadRC;
    2: Result := 0;
  else
    Result := 256;
  end;
end;

function TBits.ReadBL: Integer;
begin
  case ReadBB of
    0: Result := Integer(ReadRL);
    1: Result := ReadRC;
  else
    Result := 0;
  end;
end;

function TBits.ReadBLL: Int64;
var n, i: Integer;
begin
  n := (ReadB shl 2) or ReadBB;
  Result := 0;
  for i := 0 to n - 1 do Result := Result or (Int64(ReadRC) shl (8 * i));
end;

function TBits.ReadBD: Double;
begin
  case ReadBB of
    0: Result := ReadRD;
    1: Result := 1;
  else
    Result := 0;
  end;
end;

function TBits.ReadDD(Def: Double): Double;
var
  b: array[0..7] of Byte;
  i: Integer;
begin
  case ReadBB of
    0: Result := Def;
    1:
      begin
        Move(Def, b[0], 8);
        for i := 0 to 3 do b[i] := ReadRC;
        Move(b[0], Result, 8);
      end;
    2:
      begin
        Move(Def, b[0], 8);
        b[4] := ReadRC;
        b[5] := ReadRC;
        for i := 0 to 3 do b[i] := ReadRC;
        Move(b[0], Result, 8);
      end;
  else
    Result := ReadRD;
  end;
  if IsNan(Result) or IsInfinite(Result) then Result := 0;
end;

function TBits.ReadMC: Int64;
var
  b: Byte;
  sh, n: Integer;
begin
  Result := 0;
  sh := 0;
  for n := 0 to 9 do
  begin
    b := ReadRC;
    if (b and $80) = 0 then
    begin
      Result := Result or (Int64(b and $3F) shl sh);
      if (b and $40) <> 0 then Result := -Result;
      Exit;
    end;
    Result := Result or (Int64(b and $7F) shl sh);
    Inc(sh, 7);
  end;
end;

function TBits.ReadUMC: Int64;
var
  b: Byte;
  sh, n: Integer;
begin
  Result := 0;
  sh := 0;
  for n := 0 to 9 do
  begin
    b := ReadRC;
    Result := Result or (Int64(b and $7F) shl sh);
    if (b and $80) = 0 then Exit;
    Inc(sh, 7);
  end;
end;

function TBits.ReadMS: Int64;
var
  w: Word;
  sh, n: Integer;
begin
  Result := 0;
  sh := 0;
  for n := 0 to 4 do
  begin
    w := ReadRS;
    Result := Result or (Int64(w and $7FFF) shl sh);
    if (w and $8000) = 0 then Exit;
    Inc(sh, 15);
  end;
end;

function TBits.ReadH(out Code: Integer): Int64;
var
  b: Byte;
  i, n: Integer;
begin
  b := ReadRC;
  Code := b shr 4;
  n := b and 15;
  Result := 0;
  for i := 1 to n do Result := (Result shl 8) or ReadRC;
end;

// a handle reference, relative codes resolved against the object's handle
function TBits.ReadHRef(Ref: Int64): Int64;
var c: Integer; v: Int64;
begin
  v := ReadH(c);
  case c of
    6: Result := Ref + 1;
    8: Result := Ref - 1;
    $A: Result := Ref + v;
    $C: Result := Ref - v;
  else
    Result := v;
  end;
end;

function TBits.ReadOT: Integer;
begin
  case ReadBB of
    0: Result := ReadRC;
    1: Result := ReadRC + $1F0;
  else
    Result := ReadRS;
  end;
end;

function TBits.Read2RD: TCadVec;
begin
  Result.X := ReadRD;
  Result.Y := ReadRD;
  Result.Z := 0;
end;

function TBits.Read2BD: TCadVec;
begin
  Result.X := ReadBD;
  Result.Y := ReadBD;
  Result.Z := 0;
end;

function TBits.Read3BD: TCadVec;
begin
  Result.X := ReadBD;
  Result.Y := ReadBD;
  Result.Z := ReadBD;
end;

function TBits.ReadBE: TCadVec;
begin
  if (Ver >= R2000) and (ReadB = 1) then Result := CadVec(0, 0, 1)
  else Result := Read3BD;
end;

function TBits.ReadBT: Double;
begin
  if (Ver >= R2000) and (ReadB = 1) then Result := 0
  else Result := ReadBD;
end;

function TBits.ReadTV: string;
var
  n, i: Integer;
  b: TBytes;
begin
  n := ReadBS;
  if (n <= 0) or (Pos + Int64(n) * 8 > Limit) then
  begin
    if n > 0 then Bad := True;
    Exit('');
  end;
  SetLength(b, n);
  for i := 0 to n - 1 do b[i] := ReadRC;
  while (n > 0) and (b[n - 1] = 0) do Dec(n);
  Result := XVCodePageToUtf8(b, 0, n, CodePage);
end;

function TBits.ReadTU: string;
var
  n, i: Integer;
  b: TBytes;
begin
  n := ReadBS;
  if (n <= 0) or (Pos + Int64(n) * 16 > Limit) then
  begin
    if n > 0 then Bad := True;
    Exit('');
  end;
  SetLength(b, 2 * n);
  for i := 0 to n - 1 do
  begin
    b[2 * i] := ReadRC;
    b[2 * i + 1] := ReadRC;
  end;
  while (n > 0) and (b[2 * n - 1] = 0) and (b[2 * n - 2] = 0) do Dec(n);
  Result := XVUtf16ToUtf8(b, 0, 2 * n);
end;

// ------------------------------ decompression ------------------------------

// R2004 and later: the DWG variant of LZ77
function Decompress2004(const Src: TBytes; SrcPos, SrcLen: Integer; var Dst: TBytes; DstPos, DstLen: Integer): Integer;
var
  s, e, d, dEnd, lit, compBytes, compOffset, k: Integer;
  op1, op2: Byte;

  function NextB: Byte;
  begin
    if s < e then Result := Src[s] else Result := $11;
    Inc(s);
  end;

  function LiteralLength(Op: Byte): Integer;
  var b: Byte;
  begin
    if Op = 0 then
    begin
      Result := $0F;
      b := NextB;
      while (b = 0) and (s <= e) do
      begin
        Inc(Result, $FF);
        b := NextB;
      end;
      Result := Result + b + 3;
    end
    else Result := Op + 3;
  end;

  function LongOffset: Integer;
  var b: Byte;
  begin
    Result := 0;
    b := NextB;
    if b = 0 then
    begin
      Result := $FF;
      b := NextB;
      while (b = 0) and (s <= e) do
      begin
        Inc(Result, $FF);
        b := NextB;
      end;
    end;
    Result := Result + b;
  end;

  function TwoByteOffset(var L: Integer): Integer;
  var b1, b2: Byte;
  begin
    b1 := NextB;
    b2 := NextB;
    Result := (b1 shr 2) or (b2 shl 6);
    L := b1 and 3;
  end;

  procedure CopyLit(N: Integer);
  begin
    while (N > 0) and (s < e) do
    begin
      if d < dEnd then Dst[d] := Src[s];
      Inc(d); Inc(s); Dec(N);
    end;
  end;

begin
  s := SrcPos;
  e := Min(SrcPos + SrcLen, Length(Src));
  d := DstPos;
  dEnd := Min(DstPos + DstLen, Length(Dst));
  op1 := NextB;
  while s <= e do
  begin
    if op1 < $10 then
    begin
      CopyLit(LiteralLength(op1));
      op1 := NextB;
      Continue;
    end;
    if op1 = $11 then Break;
    lit := 0;
    if op1 >= $40 then
    begin
      compBytes := (op1 shr 4) - 1;
      op2 := NextB;
      compOffset := ((op2 shl 2) or ((op1 and $0C) shr 2)) + 1;
      lit := op1 and 3;
    end
    else if op1 >= $21 then
    begin
      compBytes := op1 - $1E;
      compOffset := TwoByteOffset(lit) + 1;
    end
    else if op1 = $20 then
    begin
      compBytes := LongOffset + $21;
      compOffset := TwoByteOffset(lit) + 1;
    end
    else
    begin
      // 0x10, 0x12 .. 0x1F: offsets from 0x4000
      if op1 = $10 then compBytes := LongOffset + 9
      else compBytes := (op1 and $0F) + 2;
      compOffset := TwoByteOffset(lit) + $4000;
    end;
    for k := 1 to compBytes do
    begin
      if (d < dEnd) and (d - compOffset >= DstPos) then Dst[d] := Dst[d - compOffset];
      Inc(d);
    end;
    if lit > 0 then CopyLit(lit);
    op1 := NextB;
  end;
  Result := d - DstPos;
end;

// R2007: R21 compression. Literal runs are stored with their 8 byte groups
// in reverse order (pieces as in the table below).
const
  LIT_PIECES: array[1..31] of string = (
    #1, #2, #3, #4, #4#1, #1#4#1, #1#4#2, #8, #8#1, #1#8#1, #1#8#2, #8#4, #8#4#1, #1#8#4#1, #1#8#4#2, #16,
    #8#1#8, #1#16#1, #16#3, #16#4, #16#4#1, #16#4#2, #16#4#3, #16#8, #16#1#8, #16#1#8#1, #16#1#8#2, #16#8#4,
    #16#8#4#1, #16#8#4#2, #2#16#8#4#1);

procedure CopyPiece(const Src: TBytes; S: Integer; var Dst: TBytes; D, N: Integer);
var i: Integer;
begin
  case N of
    1: Dst[D] := Src[S];
    2: begin Dst[D] := Src[S + 1]; Dst[D + 1] := Src[S]; end;
    3: begin Dst[D] := Src[S + 2]; Dst[D + 1] := Src[S + 1]; Dst[D + 2] := Src[S]; end;
    4: for i := 0 to 3 do Dst[D + i] := Src[S + i];
    8: for i := 0 to 7 do Dst[D + i] := Src[S + i];
    16: begin CopyPiece(Src, S + 8, Dst, D, 8); CopyPiece(Src, S, Dst, D + 8, 8); end;
  end;
end;

function Decompress21(const Src: TBytes; SrcPos, SrcLen: Integer; DstLen: Integer): TBytes;
var
  s, e, d, len, ofs: Integer;
  op: Byte;
  dst: TBytes;
  pieces: string;
  offs: array[0..7] of Integer;

  function NextB: Byte;
  begin
    if s < e then Result := Src[s] else Result := 0;
    Inc(s);
  end;

  function LiteralLength(Op: Byte): Integer;
  var n: Integer;
  begin
    Result := Op + 8;
    if Result = $17 then
    begin
      n := NextB;
      Inc(Result, n);
      if n = $FF then
        repeat
          n := NextB;
          n := n or (NextB shl 8);
          Inc(Result, n);
        until (n <> $FFFF) or (s >= e);
    end;
  end;

  procedure Instructions;
  begin
    case op shr 4 of
      0:
        begin
          len := (op and $F) + $13;
          ofs := NextB;
          op := NextB;
          len := ((op shr 3) and $10) + len;
          ofs := ((op and $78) shl 5) + 1 + ofs;
        end;
      1:
        begin
          len := (op and $F) + 3;
          ofs := NextB;
          op := NextB;
          ofs := ((op and $F8) shl 5) + 1 + ofs;
        end;
      2:
        begin
          ofs := NextB;
          ofs := ((NextB shl 8) and $FF00) or ofs;
          len := op and 7;
          if (op and 8) = 0 then
          begin
            op := NextB;
            len := (op and $F8) + len;
          end
          else
          begin
            Inc(ofs);
            len := (NextB shl 3) + len;
            op := NextB;
            len := (((op and $F8) shl 8) + len) + $100;
          end;
        end;
    else
      begin
        len := op shr 4;
        ofs := op and 15;
        op := NextB;
        ofs := (((op and $F8) shl 1) + ofs) + 1;
      end;
    end;
  end;

  procedure LitCopy(N: Integer);
  var k, p, n2: Integer;
  begin
    if (s + N > e) then N := Max(0, e - s);
    if d + N > Length(dst) then SetLength(dst, d + N + 64);
    while N >= 32 do
    begin
      CopyPiece(Src, s + 16, dst, d, 16);
      CopyPiece(Src, s, dst, d + 16, 16);
      Inc(s, 32); Inc(d, 32); Dec(N, 32);
    end;
    if N > 0 then
    begin
      pieces := LIT_PIECES[N];
      p := 0;
      for k := 1 to Length(pieces) do
      begin
        offs[k - 1] := p;
        Inc(p, Ord(pieces[k]));
      end;
      n2 := d;
      for k := Length(pieces) downto 1 do
      begin
        CopyPiece(Src, s + offs[k - 1], dst, n2, Ord(pieces[k]));
        Inc(n2, Ord(pieces[k]));
      end;
      Inc(s, N); Inc(d, N);
    end;
  end;

  procedure MatchCopy;
  var k: Integer;
  begin
    if d + len > Length(dst) then SetLength(dst, d + len + 64);
    for k := 1 to len do
    begin
      if d - ofs >= 0 then dst[d] := dst[d - ofs];
      Inc(d);
    end;
  end;

begin
  SetLength(dst, DstLen);
  s := SrcPos;
  e := Min(SrcPos + SrcLen, Length(Src));
  d := 0;
  len := 0;
  ofs := 0;
  op := NextB;
  if (op and $F0) = $20 then
  begin
    Inc(s, 2);
    len := NextB and 7;
  end;
  while s < e do
  begin
    if len = 0 then len := LiteralLength(op);
    LitCopy(len);
    len := 0;
    if s >= e then Break;
    op := NextB;
    Instructions;
    while True do
    begin
      MatchCopy;
      len := op and 7;
      if (len <> 0) or (s >= e) then Break;
      op := NextB;
      if (op shr 4) = 0 then Break;
      if (op shr 4) = $F then op := op and $F;
      Instructions;
    end;
  end;
  SetLength(dst, DstLen);
  Result := dst;
end;

// Reed-Solomon interleaved blocks: the data bytes of each block
function Deinterleave(const Src: TBytes; Ofs, BlockCount, K: Integer): TBytes;
var i, j, p: Integer;
begin
  SetLength(Result, BlockCount * K);
  for j := 0 to BlockCount - 1 do
    for i := 0 to K - 1 do
    begin
      p := Ofs + i * BlockCount + j;
      if p < Length(Src) then Result[j * K + i] := Src[p] else Result[j * K + i] := 0;
    end;
end;

function GetRL(const B: TBytes; P: Integer): Cardinal;
begin
  if P + 4 > Length(B) then Exit(0);
  Result := B[P] or (B[P + 1] shl 8) or (B[P + 2] shl 16) or (Cardinal(B[P + 3]) shl 24);
end;

function GetRLL(const B: TBytes; P: Integer): Int64;
begin
  Result := Int64(GetRL(B, P)) or (Int64(GetRL(B, P + 4)) shl 32);
end;

// ------------------------------ reader -------------------------------------

constructor TDwgReader.Create;
begin
  inherited Create;
  BlockRecs := TDictionary<Int64, TDwgBlockRec>.Create;
  LayerIdx := TDictionary<Int64, Integer>.Create;
  LTypeNames := TDictionary<Int64, string>.Create;
  StyleNames := TDictionary<Int64, string>.Create;
  LayerLTypeH := TDictionary<Int64, Int64>.Create;
  ImageDefs := TDictionary<Int64, string>.Create;
  Debug := GetEnvironmentVariable('XV_DWGDEBUG') <> '';
end;

destructor TDwgReader.Destroy;
begin
  BlockRecs.Free;
  LayerIdx.Free;
  LTypeNames.Free;
  StyleNames.Free;
  LayerLTypeH.Free;
  ImageDefs.Free;
  inherited Destroy;
end;

procedure TDwgReader.Log(const S: string);
begin
  if Debug then WriteLn(StdErr, S);
end;

function TDwgReader.SectionData(const Name: string; out Buf: TBytes): Boolean;
var i: Integer;
begin
  for i := 0 to High(Sections) do
    if SameText(Sections[i].Name, Name) then
    begin
      Buf := Sections[i].Data;
      Exit(Length(Buf) > 0);
    end;
  Buf := nil;
  Result := False;
end;

// R13 - R2000: section locators in the file header
procedure TDwgReader.ReadR2000;
var
  n, i, rec, seeker, size: Integer;
begin
  n := GetRL(Data, $15);
  for i := 0 to Min(n, 10) - 1 do
  begin
    rec := Data[$19 + i * 9];
    seeker := GetRL(Data, $19 + i * 9 + 1);
    size := GetRL(Data, $19 + i * 9 + 5);
    Log(Format('locator %d: %d at %d size %d', [i, rec, seeker, size]));
    if (seeker <= 0) or (seeker >= Length(Data)) then Continue;
    case rec of
      1: ReadClasses(Data, seeker, size);
      2: ReadObjectMap(Data, seeker, size);
    end;
  end;
  ObjBuf := Data;
end;

// R2004, R2010 and later: page map, section map, compressed pages
procedure TDwgReader.ReadR2004;
var
  hdr, buf, sec: TBytes;
  seed: Cardinal;
  i, j, k, p, nDesc, pageCount, compressed, num, pagesMapId, sectionMapId: Integer;
  pagesMapAddr, addr, secSize, startOfs: Int64;
  pageAddr: TDictionary<Integer, Int64>;
  decompSize, compSize, maxDecomp: Integer;
  name: string;
  pnum, dsize: Integer;
  mask: Cardinal;
  ph: array[0..7] of Cardinal;

  function SysPage(Address: Int64; out Res: TBytes): Boolean;
  var dsz, csz: Integer;
  begin
    Result := False;
    Res := nil;
    if (Address < 0) or (Address + 20 > Length(Data)) then Exit;
    dsz := GetRL(Data, Address + 4);
    csz := GetRL(Data, Address + 8);
    if (dsz <= 0) or (dsz > 64 * 1024 * 1024) then Exit;
    SetLength(Res, dsz);
    if GetRL(Data, Address + 12) = 2 then Decompress2004(Data, Address + 20, csz, Res, 0, dsz)
    else Move(Data[Address + 20], Res[0], Min(dsz, Length(Data) - Address - 20));
    Result := True;
  end;

begin
  // the encrypted header at 0x80
  SetLength(hdr, $6C);
  seed := 1;
  for i := 0 to $6B do
  begin
    seed := seed * $343FD + $269EC3;
    hdr[i] := Data[$80 + i] xor Byte(seed shr 16);
  end;
  pagesMapId := GetRL(hdr, $50);
  pagesMapAddr := GetRLL(hdr, $54) + $100;
  sectionMapId := GetRL(hdr, $5C);
  Log(Format('R2004 header: %s pagemap id %d at %d, section map id %d', [Copy(TEncoding.ANSI.GetString(hdr), 1, 11),
    pagesMapId, pagesMapAddr, sectionMapId]));
  pageAddr := TDictionary<Integer, Int64>.Create;
  try
    if not SysPage(pagesMapAddr, buf) then raise EDwgError.Create('DWG: no page map');
    addr := $100;
    p := 0;
    while p + 8 <= Length(buf) do
    begin
      num := Integer(GetRL(buf, p));

      k := Integer(GetRL(buf, p + 4));
      Inc(p, 8);
      if num >= 0 then pageAddr.AddOrSetValue(num, addr)
      else Inc(p, 16);
      Inc(addr, k);
    end;
    if not pageAddr.TryGetValue(sectionMapId, addr) or not SysPage(addr, buf) then
      raise EDwgError.Create('DWG: no section map');
    nDesc := GetRL(buf, 0);
    p := 20;
    SetLength(Sections, 0);
    for i := 0 to nDesc - 1 do
    begin
      if p + 96 > Length(buf) then Break;
      secSize := GetRLL(buf, p);
      pageCount := GetRL(buf, p + 8);
      maxDecomp := GetRL(buf, p + 12);
      if maxDecomp <= 0 then maxDecomp := $7400;
      compressed := GetRL(buf, p + 20);
      j := p + 32;
      name := '';
      while (j < p + 96) and (buf[j] <> 0) do
      begin
        name := name + Chr(buf[j]);
        Inc(j);
      end;
      Inc(p, 96);
      SetLength(sec, secSize);
      for k := 0 to pageCount - 1 do
      begin
        if p + 16 > Length(buf) then Break;
        pnum := GetRL(buf, p);
        dsize := GetRL(buf, p + 4);
        startOfs := GetRLL(buf, p + 8);
        Inc(p, 16);
        if not pageAddr.TryGetValue(pnum, addr) or (addr + 32 > Length(Data)) then Continue;
        // the page header, xor-ed with its address
        mask := $4164536B xor Cardinal(addr);
        for j := 0 to 7 do ph[j] := GetRL(Data, addr + 4 * j) xor mask;
        compSize := ph[2];
        // ph[3] is the size of the page in the file
        if (compSize <= 0) or (addr + 32 + compSize > Length(Data)) then compSize := Min(dsize, Length(Data) - addr - 32);
        decompSize := maxDecomp;
        if startOfs >= secSize then Continue;
        Log(Format('  page %d at %d: start %d comp %d hdr %d %d %d %d', [pnum, addr, startOfs, compSize, ph[0], ph[1], ph[4], ph[3]]));
        decompSize := Min(decompSize, secSize - startOfs);
        if compressed = 2 then
        begin
          j := Decompress2004(Data, addr + 32, compSize, sec, startOfs, decompSize);
          if j < decompSize then Log(Format('  page %d: %d of %d bytes (compressed %d)', [pnum, j, decompSize, compSize]));
        end
        else Move(Data[addr + 32], sec[startOfs], Min(decompSize, Min(compSize, Length(Data) - addr - 32)));
      end;
      SetLength(Sections, Length(Sections) + 1);
      Sections[High(Sections)].Name := name;
      Sections[High(Sections)].Data := sec;
      sec := nil;
      Log(Format('section %s: %d bytes, %d pages', [name, secSize, pageCount]));
    end;
  finally
    pageAddr.Free;
  end;
  if SectionData('AcDb:Classes', buf) then ReadClasses(buf, 0, Length(buf));
  if SectionData('AcDb:Handles', buf) then ReadObjectMap(buf, 0, Length(buf));
  SectionData('AcDb:AcDbObjects', ObjBuf);
end;

// R2007: Reed-Solomon protected header and pages, R21 compression
procedure TDwgReader.ReadR2007;
type
  TPage = record Offset, Size: Int64; end;
var
  raw, hdr, buf, sec: TBytes;
  compLen, i, k, p, blockCount, nPages: Integer;
  h: array[0..33] of Int64;
  pages: TDictionary<Int64, TPage>;
  pg: TPage;
  dataSize, nameLen, pOfs, pId, pUncomp, pComp, encoding: Int64;
  name: string;

  // a page of BlockCount interleaved Reed-Solomon blocks, K data bytes each
  function ReadPage(FileOfs: Int64; BlockCount, K: Integer; Comp, Uncomp: Int64): TBytes;
  var dec: TBytes;
  begin
    Result := nil;
    if (FileOfs < 0) or (FileOfs >= Length(Data)) or (BlockCount <= 0) or (Uncomp <= 0) or
      (Uncomp > 256 * 1024 * 1024) then Exit;
    dec := Deinterleave(Data, FileOfs, BlockCount, K);
    if Comp < Uncomp then Result := Decompress21(dec, 0, Comp, Uncomp)
    else Result := Copy(dec, 0, Uncomp);
  end;

  // the page map; True when the page map's own entry is where the header says
  function PagesMap(BlockCount: Integer): Boolean;
  var b: TBytes; q: Integer; ofs, sz, id: Int64;
  begin
    Result := False;
    b := ReadPage($480 + h[7], BlockCount, 239, h[10], h[11]);
    if Length(b) = 0 then Exit;
    pages.Clear;
    ofs := 0;
    q := 0;
    while q + 16 <= Length(b) do
    begin
      sz := GetRLL(b, q);
      id := GetRLL(b, q + 8);
      Inc(q, 16);
      if (sz < 0) or (sz > Length(Data)) then Exit;
      pg.Offset := ofs;
      pg.Size := sz;
      if id > 0 then pages.AddOrSetValue(id, pg);
      Inc(ofs, sz);
    end;
    Result := pages.TryGetValue(h[8], pg) and (pg.Offset = h[7]);
  end;

begin
  // the file header: 3 interleaved blocks of 239 data bytes
  raw := Deinterleave(Data, $80, 3, 239);
  compLen := Integer(GetRL(raw, 24));
  if compLen < 0 then hdr := Copy(raw, 32, -compLen)
  else hdr := Decompress21(raw, 32, compLen, $110);
  for i := 0 to 33 do h[i] := GetRLL(hdr, i * 8);
  Log(Format('R2007 header: file size %d, page map at %d id %d (%d/%d), section map id %d (%d/%d)',
    [h[1], h[7], h[8], h[10], h[11], h[24], h[22], h[25]]));
  pages := TDictionary<Int64, TPage>.Create;
  try
    k := 0;
    for i := 1 to 512 do
      if PagesMap(i) then
      begin
        k := i;
        Break;
      end;
    if k = 0 then raise EDwgError.Create('DWG: no page map');
    if not pages.TryGetValue(h[24], pg) then raise EDwgError.Create('DWG: no section map');
    buf := ReadPage($480 + pg.Offset, (((h[22] + 7) and not 7) * Max(1, h[27]) + 238) div 239, 239, h[22], h[25]);
    p := 0;
    while p + 64 <= Length(buf) do
    begin
      dataSize := GetRLL(buf, p);
      nameLen := GetRLL(buf, p + 32);
      nPages := GetRLL(buf, p + 56);
      encoding := GetRLL(buf, p + 48);
      Inc(p, 64);
      name := '';
      if (nameLen > 0) and (p + nameLen <= Length(buf)) then
      begin
        name := XVUtf16ToUtf8(buf, p, nameLen);
        while (name <> '') and (name[Length(name)] = #0) do SetLength(name, Length(name) - 1);
        Inc(p, nameLen);
      end;
      if (dataSize < 0) or (dataSize > 512 * 1024 * 1024) or (nPages < 0) or (nPages > 100000) then Break;
      SetLength(sec, dataSize);
      for i := 0 to nPages - 1 do
      begin
        if p + 56 > Length(buf) then Break;
        pOfs := GetRLL(buf, p);
        pId := GetRLL(buf, p + 16);
        pUncomp := GetRLL(buf, p + 24);
        pComp := GetRLL(buf, p + 32);
        Inc(p, 56);
        if not pages.TryGetValue(pId, pg) then Continue;
        if encoding = 4 then
        begin
          // Reed-Solomon (255, 251) blocks
          blockCount := (((pComp + 7) and not 7) + 250) div 251;
          raw := ReadPage($480 + pg.Offset, blockCount, 251, pComp, pUncomp);
        end
        else if ($480 + pg.Offset + pComp <= Length(Data)) and (pComp > 0) then
        begin
          if pComp < pUncomp then raw := Decompress21(Data, $480 + pg.Offset, pComp, pUncomp)
          else raw := Copy(Data, $480 + pg.Offset, pUncomp);
        end
        else raw := nil;
        if (pOfs >= 0) and (pOfs < dataSize) and (Length(raw) > 0) then
          Move(raw[0], sec[pOfs], Min(Length(raw), dataSize - pOfs));
      end;
      SetLength(Sections, Length(Sections) + 1);
      Sections[High(Sections)].Name := name;
      Sections[High(Sections)].Data := sec;
      sec := nil;
      Log(Format('section %s: %d bytes, %d pages', [name, dataSize, nPages]));
    end;
  finally
    pages.Free;
  end;
  if SectionData('AcDb:Classes', buf) then ReadClasses(buf, 0, Length(buf));
  if SectionData('AcDb:Handles', buf) then ReadObjectMap(buf, 0, Length(buf));
  SectionData('AcDb:AcDbObjects', ObjBuf);
end;

// the string stream of an object or section: its end is at EndBit
procedure StringStream(var Main: TBits; EndBit: Int64; out Str: TBits);
var size, hi: Int64;
begin
  Str := Main;
  Str.Limit := 0;
  if (EndBit <= 0) or (EndBit > Main.Limit) then Exit;
  Main.Pos := EndBit - 1;
  if Main.ReadB = 0 then Exit;
  Main.Pos := EndBit - 1 - 16;
  size := Main.ReadRS;
  if (size and $8000) <> 0 then
  begin
    Main.Pos := EndBit - 1 - 32;
    hi := Main.ReadRS;
    size := (size and $7FFF) or (hi shl 15);
    Str.Pos := EndBit - 1 - 32 - size;
  end
  else Str.Pos := EndBit - 1 - 16 - size;
  if Str.Pos < 0 then Exit;
  Str.Limit := EndBit;
end;

procedure TDwgReader.ReadClasses(const Buf: TBytes; Ofs, Len: Integer);
var
  b, s: TBits;
  size, bitsize, maxNum, n, endPos, num: Int64;
  c: TDwgClass;
  item: Integer;

  function T: string;
  begin
    if Ver >= R2007 then Result := s.ReadTU else Result := b.ReadTV;
  end;

begin
  b.Init(Buf, Ofs, Len, Ver);
  b.CodePage := CodePage;
  b.Skip(128);                     // sentinel
  size := b.ReadRL;
  endPos := 160 + size * 8;
  if ((Ver > R2010) or ((Ver = R2010) and (Maint > 3))) then
  begin
    b.ReadRL;
    Inc(endPos, 32);
  end;
  bitsize := 0;
  if Ver >= R2007 then
  begin
    bitsize := b.ReadRL;
    StringStream(b, b.Pos - 32 + bitsize, s);

  end;
  // StringStream moved the cursor: start again after the size fields
  b.Pos := 160;
  if ((Ver > R2010) or ((Ver = R2010) and (Maint > 3))) then Inc(b.Pos, 32);
  if Ver >= R2007 then Inc(b.Pos, 32);
  maxNum := 0;
  if Ver >= R2004 then
  begin
    maxNum := b.ReadBS;
    b.ReadRC; b.ReadRC; b.ReadB;
  end;
  n := 0;
  while (b.Pos < endPos) and not b.Bad do
  begin
    if (Ver >= R2004) and (maxNum > 0) and (n >= maxNum - 499) then Break;
    if (Ver >= R2007) and (b.Pos >= 160 + bitsize) then Break;
    num := b.ReadBS;
    b.ReadBS;                      // proxy flags
    T; T;                          // application, C++ class
    c.Num := num;
    c.DxfName := UpperCase(T);
    b.ReadB;                       // was a zombie
    item := b.ReadBS;
    c.IsEntity := item = $1F2;
    if Ver >= R2004 then
    begin
      b.ReadBL; b.ReadBL; b.ReadBL; b.ReadBL; b.ReadBL;
    end;
    if b.Bad then Break;
    SetLength(Classes, Length(Classes) + 1);
    Classes[High(Classes)] := c;
    Inc(n);
    Log(Format('class %d %s entity=%d', [c.Num, c.DxfName, Ord(c.IsEntity)]));
  end;
end;

procedure TDwgReader.ReadObjectMap(const Buf: TBytes; Ofs, Len: Integer);
var
  p, start, secSize, n: Integer;
  b: TBits;
  h, o: Int64;
begin
  p := Ofs;
  n := 0;
  while p + 2 <= Min(Length(Buf), Ofs + Len + 4) do
  begin
    start := p;
    secSize := (Buf[p] shl 8) or Buf[p + 1];     // big-endian
    if secSize <= 2 then Break;
    b.Init(Buf, p + 2, secSize - 2, Ver);
    h := 0;
    o := 0;
    while (b.Pos shr 3 < secSize - 2) and not b.Bad do
    begin
      h := h + b.ReadUMC;
      o := o + b.ReadMC;
      if n >= Length(Map) then SetLength(Map, Max(1024, n * 2));
      Map[n].Handle := h;
      Map[n].Offset := o;
      Inc(n);
    end;
    p := start + secSize + 2;      // and the CRC
  end;
  SetLength(Map, n);
  Log(Format('object map: %d objects', [n]));
end;

function TDwgReader.ClassOf(Typ: Integer; out C: TDwgClass): Boolean;
var i: Integer;
begin
  for i := 0 to High(Classes) do
    if Classes[i].Num = Typ then
    begin
      C := Classes[i];
      Exit(True);
    end;
  Result := False;
end;

{$I XVDwgObjects.inc}

procedure TDwgReader.ReadObjects;
var i: Integer;
begin
  for i := 0 to High(Map) do
    try
      ReadObject(Map[i]);
    except
      on E: Exception do Log(Format('object %x: %s', [Map[i].Handle, E.Message]));
    end;
end;

procedure TDwgReader.Run(const AData: TBytes);
var v: string;
begin
  Data := AData;
  if Length(Data) < $100 then raise EDwgError.Create('DWG: file too short');
  SetLength(v, 6);
  Move(Data[0], v[1], 6);
  if v = 'AC1012' then Ver := R13
  else if v = 'AC1014' then Ver := R14
  else if v = 'AC1015' then Ver := R2000
  else if v = 'AC1018' then Ver := R2004
  else if v = 'AC1021' then Ver := R2007
  else if v = 'AC1024' then Ver := R2010
  else if v = 'AC1027' then Ver := R2013
  else if v = 'AC1032' then Ver := R2018
  else raise EDwgError.CreateFmt('DWG: version %s is not supported', [v]);
  Maint := Data[$0B];
  CodePage := Data[$13] or (Data[$14] shl 8);
  case CodePage of
    28: CodePage := 1250;
    29: CodePage := 1251;
    31: CodePage := 1253;
    32: CodePage := 1254;
    33: CodePage := 1255;
    34: CodePage := 1256;
    35: CodePage := 1257;
  else
    CodePage := 1252;
  end;
  Log(Format('DWG %s maint %d', [v, Maint]));
  case Ver of
    R13, R14, R2000: ReadR2000;
    R2007: ReadR2007;
  else
    ReadR2004;
  end;
  ReadObjects;
  Assemble;
end;

// ------------------------------ entry points -------------------------------

function XVIsDWG(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) > 6) and (Data[0] = Ord('A')) and (Data[1] = Ord('C')) and (Data[2] = Ord('1')) and
    (Data[3] = Ord('0')) and (Data[4] in [Ord('1')..Ord('3')]) and (Data[5] in [Ord('0')..Ord('9')]);
end;

procedure XVReadDWGDoc(Doc: TXVDocument; const Data: TBytes);
var R: TDwgReader;
begin
  R := TDwgReader.Create;
  try
    R.Cad := TCadDrawing.Create;
    try
      R.Cad.BaseDir := ExtractFilePath(Doc.SourceFile);
      R.Run(Data);
      XVCadToDocument(R.Cad, Doc);
    finally
      R.Cad.Free;
    end;
  finally
    R.Free;
  end;
end;

initialization
  XVRegisterReader('DWG', 'dwg', XVIsDWG, XVReadDWGDoc);
end.
