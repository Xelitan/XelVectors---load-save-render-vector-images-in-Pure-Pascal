unit XVReadDXF;

{$mode delphi}{$H+}
{$R-}{$Q-}

// XelVectors - AutoCAD DXF reader (ASCII and binary DXF, R12 .. 2018).
//
// The group codes are read into a CAD drawing (XVCadModel): header units,
// layers, linetypes, text styles, blocks and the entities of model space:
// LINE, POINT, CIRCLE, ARC, ELLIPSE, LWPOLYLINE, POLYLINE / VERTEX, SPLINE,
// HATCH (polyline and edge boundaries, solid, pattern and gradient fills),
// TEXT, ATTRIB, MTEXT, INSERT (arrays, attributes), DIMENSION, SOLID, TRACE,
// 3DFACE, LEADER and WIPEOUT. The drawing is then converted to the document.

interface

uses
  SysUtils, Classes, Math, XVModel, XVCadModel;

function XVIsDXF(const Data: TBytes): Boolean;
procedure XVReadDXFDoc(Doc: TXVDocument; const Data: TBytes);

implementation

type
  TDxfPair = record
    Code: Integer;
    S: string;
    F: Double;
    HasF: Boolean;
  end;

  { TDxfReader }

  TDxfReader = class
    P: array of TDxfPair;
    N: Integer;
    Cad: TCadDrawing;
    CodePage: Integer;
    Utf8: Boolean;
    ImageDefs: TStringList;        // IMAGEDEF handle=file name
    procedure Tokenize(const Data: TBytes);
    procedure TokenizeBinary(const Data: TBytes);
    function F(i: Integer): Double;
    function I_(i: Integer): Integer;
    function S(i: Integer): string;
    function Txt(i: Integer): string;
    function EntEnd(i: Integer): Integer;
    procedure Header(var i: Integer);
    procedure Tables(var i: Integer);
    procedure Blocks(var i: Integer);
    procedure Entities(var i: Integer; var L: TCadEntities; StopAt: string);
    function Entity(var i: Integer; var L: TCadEntities): Boolean;
    procedure Common(a, b: Integer; var E: TCadEntity);
    procedure ParseHatch(a, b: Integer; var E: TCadEntity);
    procedure Objects(var i: Integer);
    procedure ResolveImages;
    procedure Run(const Data: TBytes);
  end;

function XVIsDXF(const Data: TBytes): Boolean;
var
  s: string;
  n, i: Integer;
begin
  Result := False;
  if Length(Data) < 22 then Exit;
  SetLength(s, 22);
  Move(Data[0], s[1], 22);
  if Copy(s, 1, 18) = 'AutoCAD Binary DXF' then Exit(True);
  n := Min(Length(Data), 1024);
  SetLength(s, n);
  Move(Data[0], s[1], n);
  i := 1;
  while (i <= n) and (s[i] in [' ', #9, #13, #10]) do Inc(i);
  if Copy(s, i, 3) = '999' then
  begin
    // a comment first
    while (i <= n) and (s[i] <> #10) do Inc(i);
    Inc(i);
    while (i <= n) and (s[i] <> #10) do Inc(i);
    Inc(i);
    while (i <= n) and (s[i] in [' ', #9, #13, #10]) do Inc(i);
  end;
  if (i <= n) and (s[i] = '0') then
  begin
    Inc(i);
    while (i <= n) and (s[i] in [' ', #9, #13, #10]) do Inc(i);
    Result := (Copy(s, i, 7) = 'SECTION');
  end;
end;

// ------------------------------ tokens -------------------------------------

procedure TDxfReader.Tokenize(const Data: TBytes);
var
  pos, len, st, e: Integer;
  line1, line2: string;

  function NextLine(out L: string): Boolean;
  begin
    if pos >= len then Exit(False);
    st := pos;
    while (pos < len) and (Data[pos] <> 10) do Inc(pos);
    e := pos;
    if (e > st) and (Data[e - 1] = 13) then Dec(e);
    SetLength(L, e - st);
    if e > st then Move(Data[st], L[1], e - st);
    Inc(pos);
    Result := True;
  end;

begin
  pos := 0;
  len := Length(Data);
  N := 0;
  SetLength(P, Max(1024, len div 12));
  while NextLine(line1) do
  begin
    if not NextLine(line2) then Break;
    if N >= Length(P) then SetLength(P, N * 2);
    P[N].Code := StrToIntDef(Trim(line1), -1);
    P[N].S := line2;
    P[N].HasF := False;
    Inc(N);
  end;
end;

procedure TDxfReader.TokenizeBinary(const Data: TBytes);
var
  pos, len, code, st: Integer;
  d: Double;
  i16: SmallInt;
  i32: Integer;
  i64: Int64;
  v: string;
  r13: Boolean;

  function ReadStr: string;
  begin
    st := pos;
    while (pos < len) and (Data[pos] <> 0) do Inc(pos);
    SetLength(Result, pos - st);
    if pos > st then Move(Data[st], Result[1], pos - st);
    Inc(pos);
  end;

begin
  pos := 22;
  len := Length(Data);
  N := 0;
  SetLength(P, Max(1024, len div 8));
  // R13+ writes 2-byte group codes: "0" is followed by "SECTION"
  r13 := (len > 25) and (Data[23] = 0);
  while pos < len do
  begin
    if r13 then
    begin
      if pos + 2 > len then Break;
      code := Data[pos] or (Data[pos + 1] shl 8);
      Inc(pos, 2);
    end
    else
    begin
      code := Data[pos];
      Inc(pos);
      if code = 255 then
      begin
        if pos + 2 > len then Break;
        code := Data[pos] or (Data[pos + 1] shl 8);
        Inc(pos, 2);
      end;
    end;
    if N >= Length(P) then SetLength(P, N * 2);
    P[N].Code := code;
    P[N].HasF := False;
    P[N].S := '';
    case code of
      10..59, 110..149, 210..239, 460..469, 1010..1059:
        begin
          if pos + 8 > len then Break;
          Move(Data[pos], d, 8);
          Inc(pos, 8);
          P[N].F := d; P[N].HasF := True;
        end;
      60..79, 170..179, 270..289, 370..389, 400..409, 1060..1070:
        begin
          if pos + 2 > len then Break;
          Move(Data[pos], i16, 2);
          Inc(pos, 2);
          P[N].F := i16; P[N].HasF := True;
        end;
      90..99, 420..429, 440..449, 450..459, 1071:
        begin
          if pos + 4 > len then Break;
          Move(Data[pos], i32, 4);
          Inc(pos, 4);
          P[N].F := i32; P[N].HasF := True;
        end;
      160..169:
        begin
          if pos + 8 > len then Break;
          Move(Data[pos], i64, 8);
          Inc(pos, 8);
          P[N].F := i64; P[N].HasF := True;
        end;
      290..299:
        begin
          P[N].F := Data[pos]; P[N].HasF := True;
          Inc(pos);
        end;
      310..319, 1004:
        begin
          // binary chunk: length byte and data
          st := Data[pos];
          Inc(pos, 1 + st);
        end;
    else
      begin
        v := ReadStr;
        P[N].S := v;
      end;
    end;
    if P[N].HasF then P[N].S := '';
    Inc(N);
  end;
end;

function TDxfReader.F(i: Integer): Double;
begin
  if P[i].HasF then Result := P[i].F
  else Result := XVStrToFloat(P[i].S, 0);
end;

function TDxfReader.I_(i: Integer): Integer;
begin
  if P[i].HasF then Result := Round(P[i].F)
  else Result := StrToIntDef(Trim(P[i].S), Round(XVStrToFloat(P[i].S, 0)));
end;

function TDxfReader.S(i: Integer): string;
begin
  if P[i].HasF then Result := FloatToStr(P[i].F) else Result := Trim(P[i].S);
end;

// text values: UTF-8 from 2007 on, the drawing code page before
function TDxfReader.Txt(i: Integer): string;
var b: TBytes;
begin
  Result := P[i].S;
  if Utf8 or (Result = '') then Exit;
  SetLength(b, Length(Result));
  Move(Result[1], b[0], Length(Result));
  Result := XVCodePageToUtf8(b, 0, Length(b), CodePage);
end;

// index of the next "0" group (the end of the current object)
function TDxfReader.EntEnd(i: Integer): Integer;
begin
  Result := i + 1;
  while (Result < N) and (P[Result].Code <> 0) do Inc(Result);
end;

// ------------------------------ sections -----------------------------------

procedure TDxfReader.Header(var i: Integer);
var
  name, cp: string;
  j: Integer;
begin
  while (i < N) and not ((P[i].Code = 0) and (S(i) = 'ENDSEC')) do
  begin
    if P[i].Code = 9 then
    begin
      name := UpperCase(S(i));
      j := i + 1;
      if name = '$INSUNITS' then begin if (j < N) then Cad.InsUnits := I_(j); end
      else if name = '$LTSCALE' then begin if (j < N) then Cad.LTScaleGlobal := F(j); end
      else if name = '$ACADVER' then
      begin
        if j < N then Utf8 := S(j) >= 'AC1021';
      end
      else if name = '$DWGCODEPAGE' then
      begin
        cp := UpperCase(S(j));
        if Pos('ANSI_', cp) = 1 then CodePage := StrToIntDef(Copy(cp, 6, 5), 1252)
        else if Pos('DOS', cp) = 1 then CodePage := StrToIntDef(Copy(cp, 4, 5), 437);
      end
      else if (name = '$EXTMIN') or (name = '$EXTMAX') then
      begin
        while (j < N) and (P[j].Code <> 9) and (P[j].Code <> 0) do
        begin
          if name = '$EXTMIN' then
          begin
            if P[j].Code = 10 then Cad.ExtMin.X := F(j) else if P[j].Code = 20 then Cad.ExtMin.Y := F(j);
          end
          else
          begin
            if P[j].Code = 10 then Cad.ExtMax.X := F(j) else if P[j].Code = 20 then Cad.ExtMax.Y := F(j);
          end;
          Inc(j);
        end;
        Cad.HasExt := True;
      end;
    end;
    Inc(i);
  end;
end;

procedure TDxfReader.Tables(var i: Integer);
var
  kind, e: string;
  j, b, k: Integer;
  L: TCadLayer;
  lt: TCadLType;
  st: TCadStyle;
  inAcad: Boolean;
begin
  kind := '';
  while (i < N) and not ((P[i].Code = 0) and (S(i) = 'ENDSEC')) do
  begin
    if (P[i].Code = 0) and (S(i) = 'TABLE') then
    begin
      if (i + 1 < N) and (P[i + 1].Code = 2) then kind := UpperCase(S(i + 1));
      i := EntEnd(i);
      Continue;
    end;
    if P[i].Code = 0 then
    begin
      e := UpperCase(S(i));
      b := EntEnd(i);
      if (e = 'LAYER') and (kind = 'LAYER') then
      begin
        L := Default(TCadLayer);
        L.Color := 7; L.TrueColor := -1; L.LWeight := -3; L.LType := 'CONTINUOUS';
        for j := i + 1 to b - 1 do
          case P[j].Code of
            2: L.Name := Txt(j);
            62: begin k := I_(j); L.Color := Abs(k); L.Off := k < 0; end;
            420: L.TrueColor := I_(j) and $FFFFFF;
            6: L.LType := S(j);
            370: L.LWeight := I_(j);
            70: L.Frozen := (I_(j) and 1) <> 0;
          end;
        Cad.AddLayer(L);
      end
      else if (e = 'LTYPE') and (kind = 'LTYPE') then
      begin
        lt := Default(TCadLType);
        for j := i + 1 to b - 1 do
          case P[j].Code of
            2: lt.Name := S(j);
            49: begin SetLength(lt.Dashes, Length(lt.Dashes) + 1); lt.Dashes[High(lt.Dashes)] := F(j); end;
          end;
        SetLength(Cad.LTypes, Length(Cad.LTypes) + 1);
        Cad.LTypes[High(Cad.LTypes)] := lt;
      end
      else if (e = 'STYLE') and (kind = 'STYLE') then
      begin
        st := Default(TCadStyle);
        st.WidthFactor := 1;
        inAcad := False;
        for j := i + 1 to b - 1 do
          case P[j].Code of
            2: st.Name := Txt(j);
            3: st.Font := Txt(j);
            4: st.BigFont := Txt(j);
            40: st.Height := F(j);
            41: st.WidthFactor := F(j);
            50: st.Oblique := F(j);
            1001: inAcad := SameText(S(j), 'ACAD');
            1000: if inAcad and (st.Family = '') then st.Family := Txt(j);
            1071: if inAcad then
                  begin
                    k := I_(j);
                    st.Italic := (k and $01000000) <> 0;
                    st.Bold := (k and $02000000) <> 0;
                  end;
          end;
        SetLength(Cad.Styles, Length(Cad.Styles) + 1);
        Cad.Styles[High(Cad.Styles)] := st;
      end;
      i := b;
      Continue;
    end;
    Inc(i);
  end;
end;

procedure TDxfReader.Blocks(var i: Integer);
var
  b, j, bi: Integer;
  name: string;
  base: TCadVec;
begin
  while (i < N) and not ((P[i].Code = 0) and (S(i) = 'ENDSEC')) do
  begin
    if (P[i].Code = 0) and (S(i) = 'BLOCK') then
    begin
      b := EntEnd(i);
      name := '';
      base := CadVec(0, 0);
      for j := i + 1 to b - 1 do
        case P[j].Code of
          2: name := Txt(j);
          3: if name = '' then name := Txt(j);
          10: base.X := F(j);
          20: base.Y := F(j);
        end;
      bi := Cad.AddBlock(name, base);
      i := b;
      Entities(i, Cad.Blocks[bi].Ents, 'ENDBLK');
      if (i < N) and (S(i) = 'ENDBLK') then i := EntEnd(i);
      Continue;
    end;
    Inc(i);
  end;
end;

procedure TDxfReader.Entities(var i: Integer; var L: TCadEntities; StopAt: string);
begin
  while i < N do
  begin
    if P[i].Code = 0 then
    begin
      if (S(i) = 'ENDSEC') or (S(i) = StopAt) then Exit;
      Entity(i, L);                      // moves past the entity, known or not
    end
    else Inc(i);
  end;
end;

procedure AddEnt(var L: TCadEntities; const E: TCadEntity);
begin
  SetLength(L, Length(L) + 1);
  L[High(L)] := E;
end;

procedure AddPt(var A: TCadVecs; X, Y, Z: Double);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := CadVec(X, Y, Z);
end;

procedure AddD(var A: TXVDoubles; V: Double);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := V;
end;

// group codes every entity may carry
procedure TDxfReader.Common(a, b: Integer; var E: TCadEntity);
var j, v: Integer;
begin
  for j := a to b - 1 do
    case P[j].Code of
      8: E.Layer := Txt(j);
      6: E.LType := S(j);
      62: E.Color := I_(j);
      420: E.TrueColor := I_(j) and $FFFFFF;
      440: begin
             v := I_(j);
             if (v and $02000000) <> 0 then E.Transparency := 1 - (v and $FF) / 255;
           end;
      48: E.LTScale := F(j);
      370: E.LWeight := I_(j);
      60: E.Invisible := I_(j) <> 0;
      67: E.PaperSpace := I_(j) <> 0;
      210: E.Extrusion.X := F(j);
      220: E.Extrusion.Y := F(j);
      230: E.Extrusion.Z := F(j);
      39: ;
    end;
end;

// HATCH: boundary loops, pattern definition, gradient
procedure TDxfReader.ParseHatch(a, b: Integer; var E: TCadEntity);
var
  j, nl, k, ne, et, nv, i2, nk, nc, nf, nd, npl, c2: Integer;
  L: TCadLoop;
  ed: TCadEdge;
  hasBulge: Boolean;
  pl: TCadPatLine;
  gradColors: Integer;

  function Code: Integer;
  begin
    if j < b then Result := P[j].Code else Result := -1;
  end;

  function Next(c: Integer): Boolean;
  begin
    // advances to the next group with code c within the hatch
    while (j < b) and (P[j].Code <> c) do Inc(j);
    Result := j < b;
  end;

begin
  j := a;
  gradColors := 0;
  // header part up to the loop count (91)
  while (j < b) and (P[j].Code <> 91) do
  begin
    case P[j].Code of
      2: E.PatternName := S(j);
      70: E.Solid := I_(j) = 1;
      30: E.Elevation := F(j);
    end;
    Inc(j);
  end;
  if j >= b then Exit;
  nl := I_(j);
  Inc(j);
  for k := 0 to nl - 1 do
  begin
    if not Next(92) then Break;
    L := Default(TCadLoop);
    L.IsPolyline := (I_(j) and 2) <> 0;
    Inc(j);
    if L.IsPolyline then
    begin
      hasBulge := False;
      nv := 0;
      while (j < b) and (P[j].Code in [72, 73, 93]) do
      begin
        case P[j].Code of
          72: hasBulge := I_(j) <> 0;
          73: L.Closed := I_(j) <> 0;
          93: nv := I_(j);
        end;
        Inc(j);
      end;
      for i2 := 0 to nv - 1 do
      begin
        if not Next(10) then Break;
        AddPt(L.Pts, F(j), 0, 0);
        Inc(j);
        if Code = 20 then begin L.Pts[High(L.Pts)].Y := F(j); Inc(j); end;
        AddD(L.Bulges, 0);
        if hasBulge and (Code = 42) then begin L.Bulges[High(L.Bulges)] := F(j); Inc(j); end;
      end;
    end
    else
    begin
      if Code <> 93 then Next(93);
      ne := I_(j);
      Inc(j);
      for i2 := 0 to ne - 1 do
      begin
        if not Next(72) then Break;
        et := I_(j);
        Inc(j);
        ed := Default(TCadEdge);
        ed.CCW := True;
        case et of
          1: begin
               ed.Kind := cekLine;
               while (j < b) and (P[j].Code in [10, 20, 11, 21]) do
               begin
                 case P[j].Code of
                   10: ed.P1.X := F(j); 20: ed.P1.Y := F(j);
                   11: ed.P2.X := F(j); 21: ed.P2.Y := F(j);
                 end;
                 Inc(j);
               end;
             end;
          2: begin
               ed.Kind := cekArc;
               while (j < b) and (P[j].Code in [10, 20, 40, 50, 51, 73]) do
               begin
                 case P[j].Code of
                   10: ed.Center.X := F(j); 20: ed.Center.Y := F(j);
                   40: ed.Radius := F(j);
                   50: ed.StartAng := F(j); 51: ed.EndAng := F(j);
                   73: ed.CCW := I_(j) <> 0;
                 end;
                 Inc(j);
               end;
             end;
          3: begin
               ed.Kind := cekEllipse;
               while (j < b) and (P[j].Code in [10, 20, 11, 21, 40, 50, 51, 73]) do
               begin
                 case P[j].Code of
                   10: ed.Center.X := F(j); 20: ed.Center.Y := F(j);
                   11: ed.Major.X := F(j); 21: ed.Major.Y := F(j);
                   40: ed.Ratio := F(j);
                   50: ed.StartAng := F(j); 51: ed.EndAng := F(j);
                   73: ed.CCW := I_(j) <> 0;
                 end;
                 Inc(j);
               end;
             end;
          4: begin
               ed.Kind := cekSpline;
               nk := 0; nc := 0; nf := 0;
               while (j < b) and (P[j].Code in [94, 73, 74, 95, 96]) do
               begin
                 case P[j].Code of
                   94: ed.Degree := I_(j);
                   95: nk := I_(j);
                   96: nc := I_(j);
                 end;
                 Inc(j);
               end;
               while (j < b) and (P[j].Code = 40) do begin AddD(ed.Knots, F(j)); Inc(j); end;
               while (j < b) and (P[j].Code in [10, 20, 42]) do
               begin
                 case P[j].Code of
                   10: AddPt(ed.Ctrl, F(j), 0, 0);
                   20: if Length(ed.Ctrl) > 0 then ed.Ctrl[High(ed.Ctrl)].Y := F(j);
                   42: AddD(ed.Weights, F(j));
                 end;
                 Inc(j);
               end;
               if Code = 97 then
               begin
                 nf := I_(j);
                 Inc(j);
                 while (j < b) and (P[j].Code in [11, 21]) do
                 begin
                   if P[j].Code = 11 then AddPt(ed.Fit, F(j), 0, 0)
                   else if Length(ed.Fit) > 0 then ed.Fit[High(ed.Fit)].Y := F(j);
                   Inc(j);
                 end;
               end;
               while (j < b) and (P[j].Code in [12, 22, 13, 23]) do Inc(j);
               if nk + nc + nf = 0 then ;
             end;
        end;
        SetLength(L.Edges, Length(L.Edges) + 1);
        L.Edges[High(L.Edges)] := ed;
      end;
    end;
    // source boundary objects
    if Code = 97 then
    begin
      nd := I_(j);
      Inc(j);
      for i2 := 0 to nd - 1 do
        if Code = 330 then Inc(j);
    end;
    SetLength(E.Loops, Length(E.Loops) + 1);
    E.Loops[High(E.Loops)] := L;
  end;
  // style, pattern lines, gradient
  while j < b do
  begin
    case P[j].Code of
      75: E.HatchStyle := I_(j);
      78:
        begin
          npl := I_(j);
          Inc(j);
          for k := 0 to npl - 1 do
          begin
            pl := Default(TCadPatLine);
            while (j < b) and (P[j].Code in [53, 43, 44, 45, 46, 79]) do
            begin
              case P[j].Code of
                53: pl.Angle := F(j);
                43: pl.Base.X := F(j); 44: pl.Base.Y := F(j);
                45: pl.Offset.X := F(j); 46: pl.Offset.Y := F(j);
                79: begin
                      nd := I_(j);
                      Inc(j);
                      for i2 := 0 to nd - 1 do
                        if (j < b) and (P[j].Code = 49) then begin AddD(pl.Dashes, F(j)); Inc(j); end;
                      Dec(j);
                    end;
              end;
              Inc(j);
            end;
            SetLength(E.PatLines, Length(E.PatLines) + 1);
            E.PatLines[High(E.PatLines)] := pl;
          end;
          Continue;
        end;
      450: E.IsGradient := I_(j) <> 0;
      460: E.GradAngle := F(j);
      461: E.GradShift := F(j);
      470: E.GradName := S(j);
      421: begin
             c2 := I_(j) and $FFFFFF;
             if gradColors = 0 then E.GradColor1 := c2 else E.GradColor2 := c2;
             Inc(gradColors);
           end;
    end;
    Inc(j);
  end;
end;

function TDxfReader.Entity(var i: Integer; var L: TCadEntities): Boolean;
var
  typ: string;
  b, j, k, vflags, nv: Integer;
  E, V: TCadEntity;
  w0, w1: Double;
  hasW: Boolean;
  mt: string;
begin
  typ := UpperCase(S(i));
  b := EntEnd(i);
  Result := True;
  E := XVNewCadEntity(ceNone);
  Common(i + 1, b, E);
  if typ = 'LINE' then
  begin
    E.Kind := ceLine;
    SetLength(E.Pts, 2);
    for j := i + 1 to b - 1 do
      case P[j].Code of
        10: E.Pts[0].X := F(j); 20: E.Pts[0].Y := F(j); 30: E.Pts[0].Z := F(j);
        11: E.Pts[1].X := F(j); 21: E.Pts[1].Y := F(j); 31: E.Pts[1].Z := F(j);
      end;
    AddEnt(L, E);
  end
  else if (typ = 'CIRCLE') or (typ = 'ARC') then
  begin
    if typ = 'CIRCLE' then E.Kind := ceCircle else E.Kind := ceArc;
    for j := i + 1 to b - 1 do
      case P[j].Code of
        10: E.Center.X := F(j); 20: E.Center.Y := F(j); 30: E.Elevation := F(j);
        40: E.Radius := F(j);
        50: E.StartAngle := F(j); 51: E.EndAngle := F(j);
      end;
    AddEnt(L, E);
  end
  else if typ = 'ELLIPSE' then
  begin
    E.Kind := ceEllipse;
    E.EndParam := 2 * Pi;
    for j := i + 1 to b - 1 do
      case P[j].Code of
        10: E.Center.X := F(j); 20: E.Center.Y := F(j);
        11: E.MajorAxis.X := F(j); 21: E.MajorAxis.Y := F(j); 31: E.MajorAxis.Z := F(j);
        40: E.Ratio := F(j);
        41: E.StartParam := F(j); 42: E.EndParam := F(j);
      end;
    AddEnt(L, E);
  end
  else if typ = 'LWPOLYLINE' then
  begin
    E.Kind := cePolyline;
    for j := i + 1 to b - 1 do
      case P[j].Code of
        70: E.Closed := (I_(j) and 1) <> 0;
        38: E.Elevation := F(j);
        43: E.ConstWidth := F(j);
        10: begin AddPt(E.Pts, F(j), 0, 0); AddD(E.Bulges, 0); end;
        20: if Length(E.Pts) > 0 then E.Pts[High(E.Pts)].Y := F(j);
        42: if Length(E.Bulges) > 0 then E.Bulges[High(E.Bulges)] := F(j);
        40: if E.ConstWidth = 0 then E.ConstWidth := Max(E.ConstWidth, F(j));
      end;
    AddEnt(L, E);
  end
  else if typ = 'POLYLINE' then
  begin
    E.Kind := cePolyline;
    vflags := 0;
    w0 := 0; w1 := 0;
    for j := i + 1 to b - 1 do
      case P[j].Code of
        70: vflags := I_(j);
        30: E.Elevation := F(j);
        40: w0 := F(j);
        41: w1 := F(j);
      end;
    E.Closed := (vflags and 1) <> 0;
    E.Is3D := (vflags and (8 or 16 or 64)) <> 0;
    if (w0 > 0) and (Abs(w0 - w1) < 1e-9) then E.ConstWidth := w0;
    i := b;
    hasW := False;
    // VERTEX entities up to SEQEND
    while (i < N) and (P[i].Code = 0) and (UpperCase(S(i)) = 'VERTEX') do
    begin
      b := EntEnd(i);
      V := XVNewCadEntity(ceNone);
      AddPt(E.Pts, 0, 0, 0);
      AddD(E.Bulges, 0);
      k := 0;
      for j := i + 1 to b - 1 do
        case P[j].Code of
          10: E.Pts[High(E.Pts)].X := F(j);
          20: E.Pts[High(E.Pts)].Y := F(j);
          30: E.Pts[High(E.Pts)].Z := F(j);
          42: E.Bulges[High(E.Bulges)] := F(j);
          40: if F(j) > 0 then begin w0 := F(j); hasW := True; end;
          70: k := I_(j);
        end;
      // polyface mesh face records carry no position
      if (k and 128) <> 0 then
      begin
        SetLength(E.Pts, Length(E.Pts) - 1);
        SetLength(E.Bulges, Length(E.Bulges) - 1);
      end;
      i := b;
    end;
    if hasW and (E.ConstWidth = 0) then E.ConstWidth := w0;
    if (i < N) and (UpperCase(S(i)) = 'SEQEND') then i := EntEnd(i);
    AddEnt(L, E);
    Exit;
  end
  else if typ = 'SPLINE' then
  begin
    E.Kind := ceSpline;
    E.Degree := 3;
    for j := i + 1 to b - 1 do
      case P[j].Code of
        70: E.Closed := (I_(j) and 1) <> 0;
        71: E.Degree := I_(j);
        40: AddD(E.Knots, F(j));
        41: AddD(E.Weights, F(j));
        10: AddPt(E.Pts, F(j), 0, 0);
        20: if Length(E.Pts) > 0 then E.Pts[High(E.Pts)].Y := F(j);
        11: AddPt(E.FitPts, F(j), 0, 0);
        21: if Length(E.FitPts) > 0 then E.FitPts[High(E.FitPts)].Y := F(j);
      end;
    AddEnt(L, E);
  end
  else if typ = 'HATCH' then
  begin
    E.Kind := ceHatch;
    ParseHatch(i + 1, b, E);
    AddEnt(L, E);
  end
  else if (typ = 'TEXT') or (typ = 'ATTRIB') or (typ = 'ATTDEF') then
  begin
    if typ = 'ATTDEF' then begin i := b; Exit; end;    // definitions are not drawn
    E.Kind := ceText;
    SetLength(E.Pts, 1);
    for j := i + 1 to b - 1 do
      case P[j].Code of
        1: E.Text := Txt(j);
        7: E.Style := Txt(j);
        10: E.Pts[0].X := F(j); 20: E.Pts[0].Y := F(j); 30: E.Elevation := F(j);
        11: begin E.AlignPt.X := F(j); E.HasAlignPt := True; end;
        21: E.AlignPt.Y := F(j);
        40: E.Height := F(j);
        41: E.WidthFactor := F(j);
        50: E.Rotation := F(j);
        51: E.Oblique := F(j);
        71: begin E.Backwards := (I_(j) and 2) <> 0; E.UpsideDown := (I_(j) and 4) <> 0; end;
        72: E.HAlign := I_(j);
        73: if typ = 'TEXT' then E.VAlign := I_(j);
        74: if typ = 'ATTRIB' then E.VAlign := I_(j);
        70: if (typ = 'ATTRIB') and ((I_(j) and 1) <> 0) then E.Invisible := True;
      end;
    AddEnt(L, E);
  end
  else if typ = 'MTEXT' then
  begin
    E.Kind := ceMText;
    SetLength(E.Pts, 1);
    mt := '';
    for j := i + 1 to b - 1 do
      case P[j].Code of
        3: mt := mt + Txt(j);
        1: E.Text := Txt(j);
        7: E.Style := Txt(j);
        10: E.Pts[0].X := F(j); 20: E.Pts[0].Y := F(j);
        11: begin E.Direction.X := F(j); E.HasDirection := True; end;
        21: E.Direction.Y := F(j);
        40: E.Height := F(j);
        41: E.RefWidth := F(j);
        44: E.LineSpacing := F(j);
        50: E.Rotation := F(j);
        71: E.Attachment := I_(j);
      end;
    E.Text := mt + E.Text;
    AddEnt(L, E);
  end
  else if typ = 'INSERT' then
  begin
    E.Kind := ceInsert;
    SetLength(E.Pts, 1);
    k := 0;
    for j := i + 1 to b - 1 do
      case P[j].Code of
        2: E.Block := Txt(j);
        10: E.Pts[0].X := F(j); 20: E.Pts[0].Y := F(j);
        41: E.Scale.X := F(j); 42: E.Scale.Y := F(j); 43: E.Scale.Z := F(j);
        50: E.Rotation := F(j);
        70: E.ColCount := Max(1, I_(j));
        71: E.RowCount := Max(1, I_(j));
        44: E.ColSpacing := F(j);
        45: E.RowSpacing := F(j);
        66: k := I_(j);
      end;
    AddEnt(L, E);
    i := b;
    // attributes: drawn where they are (world coordinates)
    if k <> 0 then
    begin
      while (i < N) and (P[i].Code = 0) and (UpperCase(S(i)) = 'ATTRIB') do Entity(i, L);
      if (i < N) and (UpperCase(S(i)) = 'SEQEND') then i := EntEnd(i);
    end;
    Exit;
  end
  else if typ = 'DIMENSION' then
  begin
    E.Kind := ceDimension;
    for j := i + 1 to b - 1 do
      if P[j].Code = 2 then E.Block := Txt(j);
    AddEnt(L, E);
  end
  else if (typ = 'SOLID') or (typ = 'TRACE') or (typ = '3DFACE') then
  begin
    if typ = '3DFACE' then E.Kind := ceFace else E.Kind := ceSolid;
    SetLength(E.Pts, 4);
    for j := i + 1 to b - 1 do
      case P[j].Code of
        10: E.Pts[0].X := F(j); 20: E.Pts[0].Y := F(j);
        11: E.Pts[1].X := F(j); 21: E.Pts[1].Y := F(j);
        12: E.Pts[2].X := F(j); 22: E.Pts[2].Y := F(j);
        13: E.Pts[3].X := F(j); 23: E.Pts[3].Y := F(j);
        30: E.Elevation := F(j);
      end;
    AddEnt(L, E);
  end
  else if typ = 'LEADER' then
  begin
    E.Kind := ceLeader;
    for j := i + 1 to b - 1 do
      case P[j].Code of
        10: AddPt(E.Pts, F(j), 0, 0);
        20: if Length(E.Pts) > 0 then E.Pts[High(E.Pts)].Y := F(j);
      end;
    AddEnt(L, E);
  end
  else if typ = 'IMAGE' then
  begin
    // pixel vectors U / V from the insertion point, the image file by its IMAGEDEF
    E.Kind := ceImage;
    SetLength(E.Pts, 1);
    for j := i + 1 to b - 1 do
      case P[j].Code of
        10: E.Pts[0].X := F(j); 20: E.Pts[0].Y := F(j); 30: E.Pts[0].Z := F(j);
        11: E.UVec.X := F(j); 21: E.UVec.Y := F(j); 31: E.UVec.Z := F(j);
        12: E.VVec.X := F(j); 22: E.VVec.Y := F(j); 32: E.VVec.Z := F(j);
        13: E.ImageSize.X := F(j); 23: E.ImageSize.Y := F(j);
        340: E.ImageFile := '#' + UpperCase(S(j));
        280: E.ClipOn := I_(j) <> 0;
        14: AddPt(E.ClipPts, F(j), 0, 0);
        24: if Length(E.ClipPts) > 0 then E.ClipPts[High(E.ClipPts)].Y := F(j);
      end;
    AddEnt(L, E);
  end
  else if typ = 'WIPEOUT' then
  begin
    // clip boundary in image pixel space (14/24) mapped by 10, 11, 12
    E.Kind := ceWipeout;
    for j := i + 1 to b - 1 do
      case P[j].Code of
        10: E.Center.X := F(j); 20: E.Center.Y := F(j);
        11: E.MajorAxis.X := F(j); 21: E.MajorAxis.Y := F(j);
        12: E.Direction.X := F(j); 22: E.Direction.Y := F(j);
        14: AddPt(E.Pts, F(j), 0, 0);
        24: if Length(E.Pts) > 0 then E.Pts[High(E.Pts)].Y := F(j);
      end;
    // pixel space (-0.5 .. 0.5, y down) to world through the U / V vectors
    for k := 0 to High(E.Pts) do
    begin
      w0 := E.Pts[k].X + 0.5; w1 := 0.5 - E.Pts[k].Y;
      E.Pts[k] := CadVec(E.Center.X + w0 * E.MajorAxis.X + w1 * E.Direction.X,
        E.Center.Y + w0 * E.MajorAxis.Y + w1 * E.Direction.Y);
    end;
    if Length(E.Pts) = 2 then
    begin
      // a rectangle given by two corners
      SetLength(E.Pts, 4);
      E.Pts[2] := E.Pts[1];
      E.Pts[1] := CadVec(E.Pts[2].X, E.Pts[0].Y);
      E.Pts[3] := CadVec(E.Pts[0].X, E.Pts[2].Y);
    end;
    AddEnt(L, E);
  end
  else Result := False;
  i := b;
  if nv = 0 then ;
end;

// IMAGEDEF objects: the files of the images
procedure TDxfReader.Objects(var i: Integer);
var
  b, j: Integer;
  h, fn: string;
begin
  while (i < N) and not ((P[i].Code = 0) and (S(i) = 'ENDSEC')) do
  begin
    if (P[i].Code = 0) and (UpperCase(S(i)) = 'IMAGEDEF') then
    begin
      b := EntEnd(i);
      h := '';
      fn := '';
      for j := i + 1 to b - 1 do
        case P[j].Code of
          5: h := UpperCase(S(j));
          1: fn := Txt(j);
        end;
      if h <> '' then ImageDefs.Values[h] := fn;
      i := b;
      Continue;
    end;
    Inc(i);
  end;
end;

procedure TDxfReader.ResolveImages;

  procedure Fix(var L: TCadEntities);
  var k: Integer;
  begin
    for k := 0 to High(L) do
      if (L[k].Kind = ceImage) and (Copy(L[k].ImageFile, 1, 1) = '#') then
        L[k].ImageFile := ImageDefs.Values[Copy(L[k].ImageFile, 2, MaxInt)];
  end;

var k: Integer;
begin
  Fix(Cad.Ents);
  for k := 0 to High(Cad.Blocks) do Fix(Cad.Blocks[k].Ents);
end;

procedure TDxfReader.Run(const Data: TBytes);
var
  i: Integer;
  sec: string;
begin
  if (Length(Data) > 22) and (Data[0] = Ord('A')) and (Data[18] = 13) then TokenizeBinary(Data)
  else Tokenize(Data);
  CodePage := 1252;
  i := 0;
  while i < N do
  begin
    if (P[i].Code = 0) and (S(i) = 'SECTION') and (i + 1 < N) then
    begin
      sec := UpperCase(S(i + 1));
      i := i + 2;
      if sec = 'HEADER' then Header(i)
      else if sec = 'TABLES' then Tables(i)
      else if sec = 'BLOCKS' then Blocks(i)
      else if sec = 'ENTITIES' then Entities(i, Cad.Ents, 'ENDSEC')
      else if sec = 'OBJECTS' then Objects(i)
      else
        while (i < N) and not ((P[i].Code = 0) and (S(i) = 'ENDSEC')) do Inc(i);
    end
    else if (P[i].Code = 0) and (S(i) = 'EOF') then Break;
    Inc(i);
  end;
end;

procedure XVReadDXFDoc(Doc: TXVDocument; const Data: TBytes);
var R: TDxfReader;
begin
  R := TDxfReader.Create;
  try
    R.Cad := TCadDrawing.Create;
    try
      R.Cad.BaseDir := ExtractFilePath(Doc.SourceFile);
      R.ImageDefs := TStringList.Create;
      try
        R.Run(Data);
        R.ResolveImages;
      finally
        R.ImageDefs.Free;
      end;
      R.P := nil;
      XVCadToDocument(R.Cad, Doc);
    finally
      R.Cad.Free;
    end;
  finally
    R.Free;
  end;
end;

initialization
  XVRegisterReader('DXF', 'dxf', XVIsDXF, XVReadDXFDoc);
end.
