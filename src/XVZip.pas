unit XVZip;

{$mode delphi}{$H+}
{$R-}{$Q-}

// XelVectors - minimal ZIP reader (stored and deflated entries) for the
// container formats: CorelDRAW X4+ and OpenDocument drawings.

interface

uses
  SysUtils, Classes, Math, XelInflate;

type
  TXVZipEntry = record
    Name: string;
    Method: Integer;
    CompSize, Size: Cardinal;
    LocalOfs: Cardinal;
  end;
  TXVZipEntries = array of TXVZipEntry;

function XVIsZip(const D: TBytes): Boolean;
function XVZipList(const D: TBytes): TXVZipEntries;
function XVZipFind(const L: TXVZipEntries; const Name: string): Integer;
function XVZipRead(const D: TBytes; const Ent: TXVZipEntry): TBytes;
// reads an entry by name, nil when missing
function XVZipReadName(const D: TBytes; const L: TXVZipEntries; const Name: string): TBytes;

implementation

function RdLE16(const D: TBytes; p: Integer): Integer;
begin
  if (p < 0) or (p + 2 > Length(D)) then Exit(0);
  Result := D[p] or (D[p + 1] shl 8);
end;

function RdLE32(const D: TBytes; p: Integer): Cardinal;
begin
  if (p < 0) or (p + 4 > Length(D)) then Exit(0);
  Result := Cardinal(D[p]) or (Cardinal(D[p + 1]) shl 8) or (Cardinal(D[p + 2]) shl 16) or (Cardinal(D[p + 3]) shl 24);
end;

function BytesToStr(const D: TBytes; p, n: Integer): string;
begin
  Result := '';
  if (p < 0) or (n <= 0) then Exit;
  if p + n > Length(D) then n := Length(D) - p;
  if n <= 0 then Exit;
  SetLength(Result, n);
  Move(D[p], Result[1], n);
end;

function XVIsZip(const D: TBytes): Boolean;
begin
  Result := (Length(D) >= 4) and (D[0] = Ord('P')) and (D[1] = Ord('K')) and (D[2] = 3) and (D[3] = 4);
end;

function XVZipList(const D: TBytes): TXVZipEntries;
var
  eocd, p, n, i, nl, xl, cl: Integer;
  cdOfs: Cardinal;
begin
  Result := nil;
  eocd := -1;
  for p := Length(D) - 22 downto Max(0, Length(D) - 65557) do
    if RdLE32(D, p) = $06054B50 then begin eocd := p; Break; end;
  if eocd < 0 then
  begin
    // no central directory: walk the local headers
    p := 0;
    while RdLE32(D, p) = $04034B50 do
    begin
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n].Method := RdLE16(D, p + 8);
      Result[n].CompSize := RdLE32(D, p + 18);
      Result[n].Size := RdLE32(D, p + 22);
      nl := RdLE16(D, p + 26); xl := RdLE16(D, p + 28);
      Result[n].Name := BytesToStr(D, p + 30, nl);
      Result[n].LocalOfs := p;
      p := p + 30 + nl + xl + Integer(Result[n].CompSize);
      if (RdLE16(D, Integer(Result[n].LocalOfs) + 6) and 8) <> 0 then Break;   // sizes in a data descriptor
    end;
    Exit;
  end;
  n := RdLE16(D, eocd + 10);
  cdOfs := RdLE32(D, eocd + 16);
  p := cdOfs;
  SetLength(Result, n);
  for i := 0 to n - 1 do
  begin
    if RdLE32(D, p) <> $02014B50 then begin SetLength(Result, i); Break; end;
    Result[i].Method := RdLE16(D, p + 10);
    Result[i].CompSize := RdLE32(D, p + 20);
    Result[i].Size := RdLE32(D, p + 24);
    nl := RdLE16(D, p + 28); xl := RdLE16(D, p + 30); cl := RdLE16(D, p + 32);
    Result[i].LocalOfs := RdLE32(D, p + 42);
    Result[i].Name := BytesToStr(D, p + 46, nl);
    p := p + 46 + nl + xl + cl;
  end;
end;

function XVZipFind(const L: TXVZipEntries; const Name: string): Integer;
var i: Integer;
begin
  for i := 0 to High(L) do
    if SameText(L[i].Name, Name) then Exit(i);
  Result := -1;
end;

function XVZipRead(const D: TBytes; const Ent: TXVZipEntry): TBytes;
var p, nl, xl: Integer;
begin
  Result := nil;
  p := Ent.LocalOfs;
  if RdLE32(D, p) <> $04034B50 then Exit;
  nl := RdLE16(D, p + 26); xl := RdLE16(D, p + 28);
  p := p + 30 + nl + xl;
  if (p < 0) or (Int64(p) + Ent.CompSize > Length(D)) then Exit;
  case Ent.Method of
    0: begin
         SetLength(Result, Ent.CompSize);
         if Ent.CompSize > 0 then Move(D[p], Result[0], Ent.CompSize);
       end;
    8: if Ent.CompSize > 0 then
         try
           Result := InflateRaw(@D[p], Ent.CompSize);
         except
           Result := nil;      // a damaged entry reads as missing
         end;
  end;
end;

function XVZipReadName(const D: TBytes; const L: TXVZipEntries; const Name: string): TBytes;
var i: Integer;
begin
  i := XVZipFind(L, Name);
  if i < 0 then Result := nil else Result := XVZipRead(D, L[i]);
end;

end.
