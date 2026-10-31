// XelVectors - PostScript interpreter: operators, set-up and the main loop.
// Included by XVReadPS.pas.

const
  K_PX = 96 / 72;                  // device pixels per point

// ------------------------------ life cycle ---------------------------------

constructor TPSInterp.Create(ADoc: TXVDocument);
begin
  inherited Create;
  Doc := ADoc;
  Objs := TList.Create;
  GlyphCache := TDictionary<string, TPSGlyph>.Create;
  TTCache := TDictionary<PtrUInt, TPSTrueType>.Create;
  RandSeed_ := 1;
  Debug := GetEnvironmentVariable('XV_PSDEBUG') <> '';
end;

destructor TPSInterp.Destroy;
var i: Integer;
begin
  GlyphCache.Free;
  TTCache.Free;
  for i := 0 to Objs.Count - 1 do TObject(Objs[i]).Free;
  Objs.Free;
  inherited Destroy;
end;

procedure TPSInterp.AddOp(const Name: string; P: TOpProc; Code: Integer);
var
  n: Integer;
  o: TPSObj;
begin
  n := Length(Ops);
  SetLength(Ops, n + 1);
  Ops[n].Name := Name;
  Ops[n].Proc := P;
  Ops[n].Code := Code;
  o := Default(TPSObj);
  o.K := okOp;
  o.X := True;
  o.I := n;
  DictPut(SysDict, Name, o);
end;

procedure TPSInterp.AddOps(const Names: array of string; P: TOpProc);
var i: Integer;
begin
  for i := 0 to High(Names) do AddOp(Names[i], P, i);
end;

function TPSInterp.DoBind(const O: TPSObj; Lvl: Integer): TPSObj;
var
  i: Integer;
  e, v: TPSObj;
begin
  Result := O;
  if (O.K <> okArray) or (Lvl > 40) then Exit;
  for i := 0 to O.Len - 1 do
  begin
    e := O.A.Items[O.Off + i];
    if (e.K = okName) and e.X then
    begin
      if Lookup(e.N, v) and (v.K = okOp) then O.A.Items[O.Off + i] := v;
    end
    else if (e.K = okArray) and e.X then DoBind(e, Lvl + 1);
  end;
end;

// ------------------------------ helpers ------------------------------------

procedure TPSInterp.GSave;
var n: Integer;
begin
  n := Length(GStack);
  if n > 5000 then Err('limitcheck');
  SetLength(GStack, n + 1);
  GStack[n] := GS;
  GStack[n].Path := GS.Path.Copy;
end;

procedure TPSInterp.GRestore;
var n, fl: Integer;
begin
  n := Length(GStack);
  if n = 0 then Exit;
  fl := 0;
  if Length(SaveMarks) > 0 then fl := SaveMarks[High(SaveMarks)];
  GS := GStack[n - 1];
  if n > fl then SetLength(GStack, n - 1)
  else GS.Path := GStack[n - 1].Path.Copy;     // a save's state stays
end;

procedure TPSInterp.InitGraphics;
begin
  GS.CTM := DefaultCTM;
  GS.Path.Clear;
  GS.CS := csGray;
  GS.CSObj := NameObj('DeviceGray', False);
  GS.NComps := 1;
  GS.Comps[0] := 0;
  GS.Color := XV_BLACK;
  GS.PatternPaint := -1;
  GS.PatternTile := -1;
  GS.LineWidth := 1;
  GS.Cap := lcButt;
  GS.Join := ljMiter;
  GS.Miter := 10;
  GS.Dash := nil;
  GS.DashOfs := 0;
  GS.Clips := nil;
  GS.ClipSerial := 0;
  GS.Flat := 1;
end;

procedure TPSInterp.SetPage(LLX, LLY, URX, URY: Double);
begin
  if (URX <= LLX) or (URY <= LLY) then Exit;
  PageW := URX - LLX;
  PageH := URY - LLY;
  DefaultCTM := TXVMatrix.Make(K_PX, 0, 0, -K_PX, -LLX * K_PX, URY * K_PX);
  Doc.SetPageSize(PageW * K_PX, PageH * K_PX);
end;

procedure TPSInterp.AddClipPath(Rule: TXVFillRule);
var
  c: array of TPSClip;
  n: Integer;
begin
  c := Copy(GS.Clips);
  n := Length(c);
  SetLength(c, n + 1);
  c[n].Path := GS.Path.Copy;
  if c[n].Path.NCmd = 0 then c[n].Path.AddRect(-10, -10, 0.001, 0.001);   // nothing visible
  c[n].Rule := Rule;
  GS.Clips := c;
  Inc(ClipSerialGen);
  GS.ClipSerial := ClipSerialGen;
end;

// an arc in user space, CCW or CW, angles in degrees
procedure TPSInterp.ArcUser(CX, CY, R, A1, A2: Double; CCW: Boolean);
var
  sweep, t0, t1, k: Double;
  n, i: Integer;
  p, c1, c2: TXVPoint;

  function Dv(X, Y: Double): TXVPoint;
  begin
    Result := GS.CTM.Apply(X, Y);
  end;

begin
  if CCW then
  begin
    while A2 < A1 do A2 := A2 + 360;
  end
  else
    while A2 > A1 do A2 := A2 - 360;
  sweep := (A2 - A1) * Pi / 180;
  t0 := A1 * Pi / 180;
  p := Dv(CX + R * Cos(t0), CY + R * Sin(t0));
  if GS.Path.HasCurrent then GS.Path.LineTo(p.X, p.Y) else GS.Path.MoveTo(p.X, p.Y);
  if (sweep = 0) or (R = 0) then Exit;
  n := Max(1, Ceil(Abs(sweep) / (Pi / 2) - 1e-9));
  for i := 0 to n - 1 do
  begin
    t0 := A1 * Pi / 180 + sweep * i / n;
    t1 := A1 * Pi / 180 + sweep * (i + 1) / n;
    k := 4 / 3 * Tan((t1 - t0) / 4);
    c1 := Dv(CX + R * (Cos(t0) - k * Sin(t0)), CY + R * (Sin(t0) + k * Cos(t0)));
    c2 := Dv(CX + R * (Cos(t1) + k * Sin(t1)), CY + R * (Sin(t1) - k * Cos(t1)));
    p := Dv(CX + R * Cos(t1), CY + R * Sin(t1));
    GS.Path.CubicTo(c1.X, c1.Y, c2.X, c2.Y, p.X, p.Y);
  end;
end;

function TPSInterp.CvsText(const O: TPSObj): string;
begin
  case O.K of
    okInt: Result := IntToStr(O.I);
    okReal:
      begin
        Result := XVFmt(O.R, 6);
        if (Pos('.', Result) = 0) and (Pos('e', Result) = 0) then Result := Result + '.0';
      end;
    okBool: if O.I <> 0 then Result := 'true' else Result := 'false';
    okName: Result := O.N;
    okString: Result := StrOf(O);
    okOp: Result := Ops[O.I].Name;
  else
    Result := '--nostringval--';
  end;
end;

function TPSInterp.ObjEq(const A, B: TPSObj): Boolean;
begin
  if IsNum(A) and IsNum(B) then Exit(NumOf(A) = NumOf(B));
  if (A.K in [okName, okString]) and (B.K in [okName, okString]) then Exit(StrOf(A) = StrOf(B));
  if A.K <> B.K then Exit(False);
  case A.K of
    okBool, okOp, okSave: Result := A.I = B.I;
    okNull, okMark: Result := True;
    okArray: Result := (A.A = B.A) and (A.Off = B.Off) and (A.Len = B.Len);
    okDict: Result := A.D = B.D;
    okFile: Result := A.F = B.F;
  else
    Result := False;
  end;
end;

procedure TPSInterp.CopyDict(Src, Dst: TPSDict);
var
  p: TPair<string, TPSObj>;
  ko: TPSObj;
begin
  for p in Src.Map do
  begin
    Dst.Map.AddOrSetValue(p.Key, p.Value);
    if Src.Keys.TryGetValue(p.Key, ko) then Dst.Keys.AddOrSetValue(p.Key, ko);
  end;
end;

function TPSInterp.FindFont(const Key: TPSObj): TPSObj;
var
  d: TPSDict;
  k: string;
  fm: TPSObj;
begin
  k := KeyOf(Key);
  if DictGet(FontDir, k, Result) and (Result.K = okDict) then Exit;
  // not defined in the file: a stand-in, drawn with a system font
  d := NewDict(12);
  DictPut(d, 'FontName', NameObj(k, False));
  DictPut(d, 'FontType', IntObj(1));
  fm := NewArr(6);
  SetMatrixObj(fm, TXVMatrix.Make(0.001, 0, 0, 0.001, 0, 0));
  DictPut(d, 'FontMatrix', fm);
  if Pos('symbol', LowerCase(k)) > 0 then DictPut(d, 'Encoding', NewArr(256))
  else DictPut(d, 'Encoding', StdEnc);
  fm := NewArr(4);
  ArrSet(fm, 0, IntObj(0)); ArrSet(fm, 1, IntObj(-200)); ArrSet(fm, 2, IntObj(1000)); ArrSet(fm, 3, IntObj(900));
  DictPut(d, 'FontBBox', fm);
  DictPut(d, 'PaintType', IntObj(0));
  DictPut(d, 'FID', IntObj(Objs.Count));
  Result := DictObj(d);
  DictPut(FontDir, k, Result);
end;

function TPSInterp.ScaledFont(const F: TPSObj; const M: TXVMatrix): TPSObj;
var
  d: TPSDict;
  o, fm: TPSObj;
  cur: TXVMatrix;
begin
  if F.K <> okDict then Err('typecheck');
  d := NewDict(F.D.Map.Count + 2);
  CopyDict(F.D, d);
  cur := TXVMatrix.Make(0.001, 0, 0, 0.001, 0, 0);
  if DictGet(F.D, 'FontMatrix', o) and (o.K = okArray) and (o.Len >= 6) then cur := MatrixOf(o);
  fm := NewArr(6);
  SetMatrixObj(fm, XVMul(M, cur));
  DictPut(d, 'FontMatrix', fm);
  Result := DictObj(d);
end;

procedure TPSInterp.SetError(const Name: string);
begin
  DictPut(DError, 'newerror', BoolObj(True));
  DictPut(DError, 'errorname', NameObj(Name, False));
  DictPut(DError, 'command', NameObj(CurCmd, False));
end;

function TPSInterp.TempFile(const O: TPSObj): TPSFile;
begin
  Result := TPSFile.Create;
  Objs.Add(Result);
  if O.K = okString then
  begin
    SetLength(Result.Data, O.Len);
    if O.Len > 0 then Move(O.S.Data[O.Off], Result.Data[0], O.Len);
  end;
end;

function TPSInterp.FileObj(F: TPSFile): TPSObj;
begin
  Result := Default(TPSObj);
  Result.K := okFile;
  Result.F := F;
end;

// rectangles of rectfill & co: x y w h, or an array of them
function TPSInterp.PopRects: TXVDoubles;
var
  o: TPSObj;
  i: Integer;
begin
  Result := nil;
  if (OSN > 0) and (Top^.K = okArray) then
  begin
    o := Pop;
    SetLength(Result, (o.Len div 4) * 4);
    for i := 0 to High(Result) do Result[i] := NumOf(ArrItem(o, i));
  end
  else if (OSN > 0) and (Top^.K = okString) then Pop
  else
  begin
    SetLength(Result, 4);
    for i := 3 downto 0 do Result[i] := PopNum;
  end;
end;

procedure TPSInterp.RectsToPath(const R: TXVDoubles);
var
  i: Integer;
  p: TXVPoint;
begin
  i := 0;
  while i + 3 <= High(R) do
  begin
    p := GS.CTM.Apply(R[i], R[i + 1]); GS.Path.MoveTo(p.X, p.Y);
    p := GS.CTM.Apply(R[i] + R[i + 2], R[i + 1]); GS.Path.LineTo(p.X, p.Y);
    p := GS.CTM.Apply(R[i] + R[i + 2], R[i + 1] + R[i + 3]); GS.Path.LineTo(p.X, p.Y);
    p := GS.CTM.Apply(R[i], R[i + 1] + R[i + 3]); GS.Path.LineTo(p.X, p.Y);
    GS.Path.Close;
    Inc(i, 4);
  end;
end;

function TPSInterp.SubStr(const O: TPSObj; Off, Len: Integer): TPSObj;
begin
  if (Off < 0) or (Len < 0) or (Off + Len > O.Len) then Err('rangecheck');
  Result := O;
  Result.Off := O.Off + Off;
  Result.Len := Len;
end;

// ------------------------------ stack operators ----------------------------

procedure TPSInterp.OpStack(Code: Integer);
var
  a, b, o: TPSObj;
  n, j, i, m: Integer;
  tmp: array of TPSObj;
  d: TPSDict;
begin
  case Code of
    0: Pop;
    1: begin b := Pop; a := Pop; Push(b); Push(a); end;
    2: Push(Top^);
    3:
      begin
        o := Pop;
        if o.K = okInt then
        begin
          n := o.I;
          if (n < 0) or (n > OSN) then Err('rangecheck');
          for i := 0 to n - 1 do Push(OS[OSN - n]);
        end
        else
        begin
          a := Pop;
          case o.K of
            okArray:
              begin
                if a.K <> okArray then Err('typecheck');
                if a.Len > o.Len then Err('rangecheck');
                SetLength(tmp, a.Len);
                for i := 0 to a.Len - 1 do tmp[i] := a.A.Items[a.Off + i];
                for i := 0 to a.Len - 1 do o.A.Items[o.Off + i] := tmp[i];
                o.Len := a.Len;
                Push(o);
              end;
            okString:
              begin
                if a.K <> okString then Err('typecheck');
                if a.Len > o.Len then Err('rangecheck');
                if a.Len > 0 then Move(a.S.Data[a.Off], o.S.Data[o.Off], a.Len);
                o.Len := a.Len;
                Push(o);
              end;
            okDict:
              begin
                if a.K <> okDict then Err('typecheck');
                CopyDict(a.D, o.D);
                Push(o);
              end;
          else
            Err('typecheck');
          end;
        end;
      end;
    4:
      begin
        n := PopInt;
        if (n < 0) or (n >= OSN) then Err('rangecheck');
        Push(OS[OSN - 1 - n]);
      end;
    5:
      begin
        j := PopInt;
        n := PopInt;
        if (n < 0) or (n > OSN) then Err('rangecheck');
        if n = 0 then Exit;
        j := j mod n;
        if j < 0 then Inc(j, n);
        if j = 0 then Exit;
        SetLength(tmp, n);
        for i := 0 to n - 1 do tmp[i] := OS[OSN - n + i];
        for i := 0 to n - 1 do OS[OSN - n + (i + j) mod n] := tmp[i];
      end;
    6: while OSN > 0 do Pop;
    7: Push(IntObj(OSN));
    8, 11, 13:
      begin
        o := Default(TPSObj);
        o.K := okMark;
        Push(o);
      end;
    9:
      begin
        n := CountToMark;
        for i := 0 to n do Pop;
      end;
    10: Push(IntObj(CountToMark));
    12:
      begin
        n := CountToMark;
        o := NewArr(n);
        for i := 0 to n - 1 do o.A.Items[i] := OS[OSN - n + i];
        for i := 0 to n do Pop;
        Push(o);
      end;
    14:
      begin
        n := CountToMark;
        if Odd(n) then Err('rangecheck');
        d := NewDict(n div 2);
        m := OSN - n;
        i := 0;
        while i < n do
        begin
          DictPutK(d, OS[m + i], OS[m + i + 1]);
          Inc(i, 2);
        end;
        for i := 0 to n do Pop;
        Push(DictObj(d));
      end;
  end;
end;

// ------------------------------ arithmetic ---------------------------------

procedure TPSInterp.OpArith(Code: Integer);
var
  a, b: TPSObj;
  x, y: Double;
  r: Int64;
  code_: Integer;
  s: string;

  procedure PushIntOrReal(V: Int64);
  begin
    if (V > High(Integer)) or (V < Low(Integer)) then Push(RealObj(V)) else Push(IntObj(V));
  end;

  procedure KeepType(const O: TPSObj; V: Double);
  begin
    if O.K = okInt then PushIntOrReal(Round(V)) else Push(RealObj(V));
  end;

  function ParseNum(const T: string): Double;
  begin
    Val(Trim(T), Result, code_);
    if code_ <> 0 then Err('typecheck');
  end;

begin
  case Code of
    0, 1, 2:
      begin
        b := Pop; a := Pop;
        if (a.K = okInt) and (b.K = okInt) then
        begin
          case Code of
            0: r := a.I + b.I;
            1: r := a.I - b.I;
          else
            begin
              x := a.I * 1.0 * b.I;
              if Abs(x) > 2.1e9 then begin Push(RealObj(x)); Exit; end;
              r := a.I * b.I;
            end;
          end;
          PushIntOrReal(r);
        end
        else
        begin
          x := NumOf(a); y := NumOf(b);
          case Code of
            0: Push(RealObj(x + y));
            1: Push(RealObj(x - y));
          else
            Push(RealObj(x * y));
          end;
        end;
      end;
    3:
      begin
        y := PopNum; x := PopNum;
        if y = 0 then Err('undefinedresult');
        Push(RealObj(x / y));
      end;
    4, 5:
      begin
        r := PopInt;
        if r = 0 then Err('undefinedresult');
        if Code = 4 then Push(IntObj(PopInt div r)) else Push(IntObj(PopInt mod r));
      end;
    6: begin a := Pop; if a.K = okInt then PushIntOrReal(-a.I) else Push(RealObj(-NumOf(a))); end;
    7: begin a := Pop; if a.K = okInt then PushIntOrReal(Abs(a.I)) else Push(RealObj(Abs(NumOf(a)))); end;
    8: begin a := Pop; KeepType(a, Ceil(NumOf(a))); end;
    9: begin a := Pop; KeepType(a, Floor(NumOf(a))); end;
    10: begin a := Pop; KeepType(a, Floor(NumOf(a) + 0.5)); end;
    11: begin a := Pop; KeepType(a, Int(NumOf(a))); end;
    12: begin x := PopNum; if x < 0 then Err('rangecheck'); Push(RealObj(Sqrt(x))); end;
    13:
      begin
        y := PopNum; x := PopNum;     // num den
        if (x = 0) and (y = 0) then Err('undefinedresult');
        x := ArcTan2(x, y) * 180 / Pi;
        if x < 0 then x := x + 360;
        Push(RealObj(x));
      end;
    14: Push(RealObj(Cos(PopNum * Pi / 180)));
    15: Push(RealObj(Sin(PopNum * Pi / 180)));
    16:
      begin
        y := PopNum; x := PopNum;
        if (x < 0) and (Frac(y) <> 0) then Err('undefinedresult');
        if (x = 0) and (y <= 0) then Push(RealObj(0)) else Push(RealObj(Power(x, y)));
      end;
    17: begin x := PopNum; if x <= 0 then Err('rangecheck'); Push(RealObj(Ln(x))); end;
    18: begin x := PopNum; if x <= 0 then Err('rangecheck'); Push(RealObj(Log10(x))); end;
    19:
      begin
        RandSeed_ := RandSeed_ * 1103515245 + 12345;
        Push(IntObj((RandSeed_ shr 1) and $7FFFFFFF));
      end;
    20: RandSeed_ := Cardinal(PopInt);
    21: Push(IntObj(RandSeed_ and $7FFFFFFF));
    22:
      begin
        a := Pop;
        if a.K = okString then x := ParseNum(StrOf(a)) else x := NumOf(a);
        if Abs(x) > 2.1e9 then Err('rangecheck');
        Push(IntObj(Trunc(x)));
      end;
    23:
      begin
        a := Pop;
        if a.K = okString then
        begin
          s := StrOf(a);
          Push(RealObj(ParseNum(s)));
        end
        else Push(RealObj(NumOf(a)));
      end;
    24:
      begin
        r := PopInt;
        a := IntObj(PopInt);
        if r >= 0 then Push(IntObj(Int32(Cardinal(a.I) shl r)))
        else Push(IntObj(Int32(Cardinal(a.I) shr (-r))));
      end;
  end;
end;

procedure TPSInterp.OpRel(Code: Integer);
var
  a, b: TPSObj;
  c: Integer;
begin
  case Code of
    0: begin b := Pop; a := Pop; Push(BoolObj(ObjEq(a, b))); end;
    1: begin b := Pop; a := Pop; Push(BoolObj(not ObjEq(a, b))); end;
    2, 3, 4, 5:
      begin
        b := Pop; a := Pop;
        if (a.K = okString) and (b.K = okString) then c := CompareStr(StrOf(a), StrOf(b))
        else c := CompareValue(NumOf(a), NumOf(b));
        case Code of
          2: Push(BoolObj(c > 0));
          3: Push(BoolObj(c >= 0));
          4: Push(BoolObj(c < 0));
        else
          Push(BoolObj(c <= 0));
        end;
      end;
    6, 7, 8:
      begin
        b := Pop; a := Pop;
        if (a.K = okBool) and (b.K = okBool) then
        begin
          case Code of
            6: Push(BoolObj((a.I <> 0) and (b.I <> 0)));
            7: Push(BoolObj((a.I <> 0) or (b.I <> 0)));
          else
            Push(BoolObj((a.I <> 0) xor (b.I <> 0)));
          end;
        end
        else if (a.K = okInt) and (b.K = okInt) then
        begin
          case Code of
            6: Push(IntObj(a.I and b.I));
            7: Push(IntObj(a.I or b.I));
          else
            Push(IntObj(a.I xor b.I));
          end;
        end
        else Err('typecheck');
      end;
    9:
      begin
        a := Pop;
        if a.K = okBool then Push(BoolObj(a.I = 0))
        else if a.K = okInt then Push(IntObj(not a.I))
        else Err('typecheck');
      end;
  end;
end;

// ------------------------------ control ------------------------------------

procedure TPSInterp.OpControl(Code: Integer);
var
  proc, a, b, c, o: TPSObj;
  i: Integer;
  n: Int64;
  x, inc_, lim: Double;
  keys, vals: array of TPSObj;
  p: TPair<string, TPSObj>;
  ko: TPSObj;
  k: Integer;
  saveDepth: Integer;
begin
  case Code of
    0: Exec(Pop);
    1:
      begin
        proc := Pop;
        if PopBool then Exec(proc);
      end;
    2:
      begin
        b := Pop; a := Pop;
        if PopBool then Exec(a) else Exec(b);
      end;
    3:
      begin
        proc := Pop; c := Pop; b := Pop; a := Pop;
        try
          if (a.K = okInt) and (b.K = okInt) and (c.K = okInt) then
          begin
            i := a.I;
            while ((b.I >= 0) and (i <= c.I)) or ((b.I < 0) and (i >= c.I)) do
            begin
              Push(IntObj(i));
              Exec(proc);
              Inc(i, b.I);
            end;
          end
          else
          begin
            x := NumOf(a); inc_ := NumOf(b); lim := NumOf(c);
            while ((inc_ >= 0) and (x <= lim)) or ((inc_ < 0) and (x >= lim)) do
            begin
              Push(RealObj(x));
              Exec(proc);
              x := x + inc_;
            end;
          end;
        except
          on EPSExit do ;
        end;
      end;
    4:
      begin
        proc := Pop;
        n := PopInt;
        try
          for i := 1 to n do Exec(proc);
        except
          on EPSExit do ;
        end;
      end;
    5:
      begin
        proc := Pop;
        try
          while True do Exec(proc);
        except
          on EPSExit do ;
        end;
      end;
    6: raise EPSExit.Create('exit');
    7:
      begin
        proc := Pop;
        o := Pop;
        try
          case o.K of
            okArray:
              for k := 0 to o.Len - 1 do
              begin
                Push(o.A.Items[o.Off + k]);
                Exec(proc);
              end;
            okString:
              for k := 0 to o.Len - 1 do
              begin
                Push(IntObj(o.S.Data[o.Off + k]));
                Exec(proc);
              end;
            okDict:
              begin
                SetLength(keys, o.D.Map.Count);
                SetLength(vals, o.D.Map.Count);
                k := 0;
                for p in o.D.Map do
                begin
                  if not o.D.Keys.TryGetValue(p.Key, ko) then ko := NameObj(p.Key, False);
                  keys[k] := ko;
                  vals[k] := p.Value;
                  Inc(k);
                end;
                for k := 0 to High(keys) do
                begin
                  Push(keys[k]);
                  Push(vals[k]);
                  Exec(proc);
                end;
              end;
          else
            Err('typecheck');
          end;
        except
          on EPSExit do ;
        end;
      end;
    8: raise EPSStop.Create('stop');
    9:
      begin
        proc := Pop;
        saveDepth := Depth;
        try
          Exec(proc);
          Push(BoolObj(False));
        except
          on EPSQuit do raise;
          on EPSExit do raise;
          on EPSStop do begin Depth := saveDepth; Push(BoolObj(True)); end;
          on E: EPSError do
          begin
            Depth := saveDepth;
            SetError(E.ErrName);
            Push(BoolObj(True));
          end;
          on E: Exception do
          begin
            Depth := saveDepth;
            SetError('unregistered');
            Push(BoolObj(True));
          end;
        end;
      end;
    10: Push(IntObj(Depth));
    11: begin o := PopArr; o.Len := 0; Push(o); end;
    12: raise EPSQuit.Create('quit');
    13: ;
  end;
end;

// ------------------------------ types --------------------------------------

procedure TPSInterp.OpType(Code: Integer);
const
  TYPE_NAMES: array[TPSKind] of string = ('nulltype', 'integertype', 'realtype', 'booleantype', 'nametype',
    'stringtype', 'arraytype', 'dicttype', 'operatortype', 'marktype', 'filetype', 'savetype');
var
  o, s: TPSObj;
  t: string;
  radix: Integer;
  v: Int64;
begin
  case Code of
    0: begin o := Pop; Push(NameObj(TYPE_NAMES[o.K], True)); end;
    1: Top^.X := False;
    2: Top^.X := True;
    3: begin o := Pop; Push(BoolObj(o.X)); end;
    4, 5, 6: ;
    7, 8: begin Pop; Push(BoolObj(True)); end;
    9:
      begin
        o := Pop;
        if o.K = okString then Push(NameObj(StrOf(o), o.X))
        else if o.K = okName then Push(o)
        else Err('typecheck');
      end;
    10:
      begin
        s := Pop;
        o := Pop;
        if s.K <> okString then Err('typecheck');
        t := CvsText(o);
        if Length(t) > s.Len then Err('rangecheck');
        if t <> '' then Move(t[1], s.S.Data[s.Off], Length(t));
        s.Len := Length(t);
        Push(s);
      end;
    11:
      begin
        s := Pop;
        radix := PopInt;
        o := Pop;
        if (radix = 10) or (radix < 2) or (radix > 36) then t := CvsText(o)
        else
        begin
          v := Cardinal(Round(NumOf(o)));
          t := '';
          repeat
            t := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'[v mod radix + 1] + t;
            v := v div radix;
          until v = 0;
        end;
        if Length(t) > s.Len then Err('rangecheck');
        if t <> '' then Move(t[1], s.S.Data[s.Off], Length(t));
        s.Len := Length(t);
        Push(s);
      end;
    12: DoBind(Top^, 0);
    13: begin o := Pop; Push(BoolObj(not (o.K in [okString, okArray, okDict, okFile]))); end;
  end;
end;

// ------------------------------ dictionaries -------------------------------

procedure TPSInterp.OpDict(Code: Integer);
var
  o, k, v: TPSObj;
  d: TPSDict;
  i, n: Integer;
  key: string;
begin
  case Code of
    0: Push(DictObj(NewDict(PopInt)));
    1:
      begin
        d := PopDict;
        if Length(DS) > 1000 then Err('dictstackoverflow');
        SetLength(DS, Length(DS) + 1);
        DS[High(DS)] := d;
      end;
    2:
      begin
        if Length(DS) <= 3 then Err('dictstackunderflow');
        SetLength(DS, Length(DS) - 1);
      end;
    3:
      begin
        v := Pop; k := Pop;
        DictPutK(DS[High(DS)], k, v);
      end;
    4:
      begin
        k := Pop;
        if not Lookup(KeyOf(k), v) then begin CurCmd := KeyOf(k); Err('undefined'); end;
        Push(v);
      end;
    5:
      begin
        v := Pop; k := Pop;
        key := KeyOf(k);
        for i := High(DS) downto 0 do
          if DS[i].Map.ContainsKey(key) then
          begin
            DictPutK(DS[i], k, v);
            Exit;
          end;
        DictPutK(DS[High(DS)], k, v);
      end;
    6:
      begin
        k := Pop;
        d := PopDict;
        Push(BoolObj(d.Map.ContainsKey(KeyOf(k))));
      end;
    7:
      begin
        k := Pop;
        key := KeyOf(k);
        for i := High(DS) downto 0 do
          if DS[i].Map.ContainsKey(key) then
          begin
            Push(DictObj(DS[i]));
            Push(BoolObj(True));
            Exit;
          end;
        Push(BoolObj(False));
      end;
    8: Push(DictObj(DS[High(DS)]));
    9: Push(IntObj(Length(DS)));
    10:
      begin
        o := PopArr;
        n := Min(o.Len, Length(DS));
        for i := 0 to n - 1 do o.A.Items[o.Off + i] := DictObj(DS[i]);
        o.Len := n;
        Push(o);
      end;
    11:
      begin
        k := Pop;
        d := PopDict;
        key := KeyOf(k);
        d.Map.Remove(key);
        d.Keys.Remove(key);
      end;
    12: begin d := PopDict; Push(IntObj(Max(d.MaxLen, d.Map.Count + 1))); end;
    13: SetLength(DS, 3);
    14: Push(BoolObj(False));
    15: Pop;
    16: Pop;
    17: Push(BoolObj(False));
    18: Push(NewArr(PopInt));
    19, 21:
      begin
        if Code = 19 then
        begin
          n := PopInt;
          o := NewArr(n);
        end
        else
        begin
          o := PopArr;
          n := o.Len;
        end;
        if n > OSN then Err('stackunderflow');
        for i := 0 to n - 1 do o.A.Items[o.Off + i] := OS[OSN - n + i];
        for i := 1 to n do Pop;
        Push(o);
      end;
    20:
      begin
        o := PopArr;
        for i := 0 to o.Len - 1 do Push(o.A.Items[o.Off + i]);
        Push(o);
      end;
    22:
      begin
        n := PopInt;
        if (n < 0) or (n > 100000000) then Err('rangecheck');
        Push(NewStr(n));
      end;
    23: begin Pop; Push(DictObj(InternalDict)); end;
  end;
end;

// ------------------------------ strings and polymorphic access -------------

procedure TPSInterp.OpString(Code: Integer);
var
  o, k, v, s, seek: TPSObj;
  i, j, n, idx: Integer;
  f: TPSFile;
  tok: TPSObj;
  found: Boolean;
begin
  case Code of
    0:
      begin
        o := Pop;
        case o.K of
          okArray, okString: Push(IntObj(o.Len));
          okDict: Push(IntObj(o.D.Map.Count));
          okName: Push(IntObj(Length(o.N)));
        else
          Err('typecheck');
        end;
      end;
    1:
      begin
        k := Pop;
        o := Pop;
        case o.K of
          okArray: Push(ArrItem(o, Round(NumOf(k))));
          okString:
            begin
              idx := Round(NumOf(k));
              if (idx < 0) or (idx >= o.Len) then Err('rangecheck');
              Push(IntObj(o.S.Data[o.Off + idx]));
            end;
          okDict:
            begin
              if not DictGet(o.D, KeyOf(k), v) then begin CurCmd := KeyOf(k); Err('undefined'); end;
              Push(v);
            end;
        else
          Err('typecheck');
        end;
      end;
    2:
      begin
        v := Pop;
        k := Pop;
        o := Pop;
        case o.K of
          okArray: ArrSet(o, Round(NumOf(k)), v);
          okString:
            begin
              idx := Round(NumOf(k));
              if (idx < 0) or (idx >= o.Len) then Err('rangecheck');
              o.S.Data[o.Off + idx] := Byte(Round(NumOf(v)));
            end;
          okDict: DictPutK(o.D, k, v);
        else
          Err('typecheck');
        end;
      end;
    3:
      begin
        n := PopInt;
        idx := PopInt;
        o := Pop;
        if not (o.K in [okArray, okString]) then Err('typecheck');
        Push(SubStr(o, idx, n));
      end;
    4:
      begin
        s := Pop;
        idx := PopInt;
        o := Pop;
        if (o.K = okArray) and (s.K = okArray) then
        begin
          if idx + s.Len > o.Len then Err('rangecheck');
          for i := 0 to s.Len - 1 do o.A.Items[o.Off + idx + i] := s.A.Items[s.Off + i];
        end
        else if (o.K = okString) and (s.K = okString) then
        begin
          if idx + s.Len > o.Len then Err('rangecheck');
          if s.Len > 0 then Move(s.S.Data[s.Off], o.S.Data[o.Off + idx], s.Len);
        end
        else Err('typecheck');
      end;
    5, 6:
      begin
        seek := PopStr;
        s := PopStr;
        idx := -1;
        n := seek.Len;
        if Code = 6 then j := 0 else j := s.Len - n;
        for i := 0 to j do
        begin
          found := True;
          if n > 0 then
            found := CompareMem(@s.S.Data[s.Off + i], @seek.S.Data[seek.Off], n);
          if found then begin idx := i; Break; end;
        end;
        if idx >= 0 then
        begin
          Push(SubStr(s, idx + n, s.Len - idx - n));
          Push(SubStr(s, idx, n));
          if Code = 5 then Push(SubStr(s, 0, idx));
          Push(BoolObj(True));
        end
        else
        begin
          Push(s);
          Push(BoolObj(False));
        end;
      end;
    7:
      begin
        o := Pop;
        if o.K = okString then
        begin
          f := TempFile(o);
          if Token(f, tok) then
          begin
            // the scanner takes one white space character after the token
            Push(SubStr(o, Min(f.Pos, o.Len), o.Len - Min(f.Pos, o.Len)));
            Push(tok);
            Push(BoolObj(True));
          end
          else Push(BoolObj(False));
        end
        else if o.K = okFile then
        begin
          if Token(o.F, tok) then
          begin
            Push(tok);
            Push(BoolObj(True));
          end
          else Push(BoolObj(False));
        end
        else Err('typecheck');
      end;
  end;
end;

// ------------------------------ graphics state -----------------------------

procedure TPSInterp.OpGState(Code: Integer);
var
  o: TPSObj;
  i, n: Integer;
  d: TXVDoubles;
  c: array[0..7] of Double;
  h, s, v, r, g, b, f, p, q, t: Double;
  hi: Integer;
  dd: TPSDict;
begin
  case Code of
    0: GSave;
    1: GRestore;
    2:
      begin
        n := 0;
        if Length(SaveMarks) > 0 then n := SaveMarks[High(SaveMarks)];
        while Length(GStack) > Max(n, 1) do GRestore;
        if Length(GStack) > 0 then GRestore;
      end;
    3:
      begin
        GSave;
        n := Length(SaveMarks);
        SetLength(SaveMarks, n + 1);
        SaveMarks[n] := Length(GStack);
        o := Default(TPSObj);
        o.K := okSave;
        o.I := n;
        Push(o);
      end;
    4:
      begin
        o := Pop;
        if o.K <> okSave then Err('typecheck');
        n := o.I;
        if (n < 0) or (n >= Length(SaveMarks)) then Exit;
        i := SaveMarks[n];
        if (i >= 1) and (i <= Length(GStack)) then
        begin
          GS := GStack[i - 1];
          SetLength(GStack, i - 1);
        end;
        SetLength(SaveMarks, n);
      end;
    5: GS.LineWidth := Abs(PopNum);
    6: Push(RealObj(GS.LineWidth));
    7: GS.Cap := TXVLineCap(EnsureRange(PopInt, 0, 2));
    8: Push(IntObj(Ord(GS.Cap)));
    9: GS.Join := TXVLineJoin(EnsureRange(PopInt, 0, 2));
    10: Push(IntObj(Ord(GS.Join)));
    11: GS.Miter := Max(1, PopNum);
    12: Push(RealObj(GS.Miter));
    13:
      begin
        GS.DashOfs := PopNum;
        o := PopArr;
        SetLength(d, o.Len);
        s := 0;
        for i := 0 to o.Len - 1 do
        begin
          d[i] := Abs(NumOf(ArrItem(o, i)));
          s := s + d[i];
        end;
        if s <= 0 then d := nil;
        GS.Dash := d;
      end;
    14:
      begin
        o := NewArr(Length(GS.Dash));
        for i := 0 to High(GS.Dash) do o.A.Items[i] := RealObj(GS.Dash[i]);
        Push(o);
        Push(RealObj(GS.DashOfs));
      end;
    15: GS.Flat := PopNum;
    16: Push(RealObj(GS.Flat));
    17:
      begin
        GS.CS := csGray;
        GS.CSObj := NameObj('DeviceGray', False);
        GS.NComps := 1;
        SetColorComps(1);
      end;
    18:
      begin
        GS.CS := csRGB;
        GS.CSObj := NameObj('DeviceRGB', False);
        GS.NComps := 3;
        SetColorComps(3);
      end;
    19:
      begin
        v := EnsureRange(PopNum, 0, 1); s := EnsureRange(PopNum, 0, 1); h := EnsureRange(PopNum, 0, 1);
        h := h * 6;
        if h >= 6 then h := 0;
        hi := Trunc(h);
        f := h - hi;
        p := v * (1 - s); q := v * (1 - s * f); t := v * (1 - s * (1 - f));
        case hi of
          0: begin r := v; g := t; b := p; end;
          1: begin r := q; g := v; b := p; end;
          2: begin r := p; g := v; b := t; end;
          3: begin r := p; g := q; b := v; end;
          4: begin r := t; g := p; b := v; end;
        else
          begin r := v; g := p; b := q; end;
        end;
        GS.CS := csRGB;
        GS.CSObj := NameObj('DeviceRGB', False);
        GS.NComps := 3;
        Push(RealObj(r)); Push(RealObj(g)); Push(RealObj(b));
        SetColorComps(3);
      end;
    20:
      begin
        GS.CS := csCMYK;
        GS.CSObj := NameObj('DeviceCMYK', False);
        GS.NComps := 4;
        SetColorComps(4);
      end;
    21: Push(RealObj((0.3 * XVColorR(GS.Color) + 0.59 * XVColorG(GS.Color) + 0.11 * XVColorB(GS.Color)) / 255));
    22, 23:
      begin
        r := XVColorR(GS.Color) / 255; g := XVColorG(GS.Color) / 255; b := XVColorB(GS.Color) / 255;
        if Code = 22 then
        begin
          Push(RealObj(r)); Push(RealObj(g)); Push(RealObj(b));
        end
        else
        begin
          v := Max(r, Max(g, b));
          s := v - Min(r, Min(g, b));
          h := 0;
          if s > 0 then
          begin
            if v = r then h := (g - b) / s
            else if v = g then h := 2 + (b - r) / s
            else h := 4 + (r - g) / s;
            h := h / 6;
            if h < 0 then h := h + 1;
          end;
          if v > 0 then s := s / v;
          Push(RealObj(h)); Push(RealObj(s)); Push(RealObj(v));
        end;
      end;
    24:
      begin
        if GS.CS = csCMYK then
          for i := 0 to 3 do Push(RealObj(GS.Comps[i]))
        else
        begin
          r := XVColorR(GS.Color) / 255; g := XVColorG(GS.Color) / 255; b := XVColorB(GS.Color) / 255;
          t := 1 - Max(r, Max(g, b));
          Push(RealObj(1 - r - t)); Push(RealObj(1 - g - t)); Push(RealObj(1 - b - t)); Push(RealObj(t));
        end;
      end;
    25:
      begin
        o := Pop;
        GS.CSObj := o;
        GS.CS := SpaceOf(o, n);
        GS.NComps := n;
        GS.PatternPaint := -1;
        GS.PatternTile := -1;
        for i := 0 to 7 do c[i] := 0;
        case GS.CS of
          csCMYK: c[3] := 1;
          csSeparation, csDeviceN: for i := 0 to 7 do c[i] := 1;
        end;
        for i := 0 to 7 do GS.Comps[i] := c[i];
        if GS.CS <> csPattern then GS.Color := CompsToColor(GS.CS, c, n, o)
        else GS.Color := XV_BLACK;
      end;
    26: SetColorComps(GS.NComps);
    27:
      begin
        if GS.CSObj.K = okArray then Push(GS.CSObj)
        else
        begin
          o := NewArr(1);
          o.A.Items[0] := GS.CSObj;
          Push(o);
        end;
      end;
    28: for i := 0 to GS.NComps - 1 do Push(RealObj(GS.Comps[i]));
    29: InitGraphics;
    30:
      begin
        o := Pop;
        GS.CS := csPattern;
        GS.CSObj := NameObj('Pattern', False);
        Push(o);
        SetColorComps(1);
      end;
    31, 32:
      begin
        if Code = 32 then Pop;
        dd := NewDict(1);
        Push(DictObj(dd));
      end;
    33: Pop;
  end;
end;

procedure TPSInterp.OpIgnore(Code: Integer);
var i: Integer;
begin
  for i := 1 to Min(Code, OSN) do Pop;
end;

// ------------------------------ matrices -----------------------------------

procedure TPSInterp.OpMatrix(Code: Integer);
var
  o, o2: TPSObj;
  m, m2: TXVMatrix;
  x, y: Double;
  p: TXVPoint;
  explicit: Boolean;
begin
  case Code of
    0:
      begin
        o := NewArr(6);
        SetMatrixObj(o, TXVMatrix.Identity);
        Push(o);
      end;
    1: GS.CTM := DefaultCTM;
    2: begin o := PopArr; SetMatrixObj(o, TXVMatrix.Identity); Push(o); end;
    3: begin o := PopArr; SetMatrixObj(o, DefaultCTM); Push(o); end;
    4: begin o := PopArr; SetMatrixObj(o, GS.CTM); Push(o); end;
    5: GS.CTM := MatrixOf(PopArr);
    6, 7:
      begin
        explicit := (OSN > 0) and (Top^.K = okArray);
        if explicit then o := PopArr;
        y := PopNum; x := PopNum;
        if Code = 6 then m := TXVMatrix.Translate(x, y) else m := TXVMatrix.Scale(x, y);
        if explicit then begin SetMatrixObj(o, m); Push(o); end
        else GS.CTM := XVMul(GS.CTM, m);
      end;
    8:
      begin
        explicit := (OSN > 0) and (Top^.K = okArray);
        if explicit then o := PopArr;
        m := TXVMatrix.Rotate(PopNum * Pi / 180);
        if explicit then begin SetMatrixObj(o, m); Push(o); end
        else GS.CTM := XVMul(GS.CTM, m);
      end;
    9: GS.CTM := XVMul(GS.CTM, MatrixOf(PopArr));
    10:
      begin
        o := PopArr;
        m2 := MatrixOf(PopArr);
        m := MatrixOf(PopArr);
        SetMatrixObj(o, XVMul(m2, m));
        Push(o);
      end;
    11, 12, 13, 14:
      begin
        if (OSN > 0) and (Top^.K = okArray) then m := MatrixOf(PopArr) else m := GS.CTM;
        y := PopNum; x := PopNum;
        if Code in [12, 14] then
        begin
          if Abs(m.Det) < 1e-300 then Err('undefinedresult');
          m := m.Invert;
        end;
        if Code in [11, 12] then p := m.Apply(x, y) else p := m.ApplyVec(x, y);
        Push(RealObj(p.X)); Push(RealObj(p.Y));
      end;
    15:
      begin
        o2 := PopArr;
        m := MatrixOf(PopArr);
        if Abs(m.Det) < 1e-300 then Err('undefinedresult');
        SetMatrixObj(o2, m.Invert);
        Push(o2);
      end;
  end;
end;

// ------------------------------ paths --------------------------------------

procedure TPSInterp.OpPath(Code: Integer);
var
  x, y, x1, y1, x2, y2, x3, y3, r, a1, a2: Double;
  p, p1, p2, p3: TXVPoint;
  rc: TXVRect;
  d1x, d1y, d2x, d2y, l1, l2, cosT, th, dist, cx, cy, sa, ea, cr: Double;
  rects: TXVDoubles;
  inv: TXVMatrix;
  i: Integer;
begin
  case Code of
    0: GS.Path.Clear;
    1:
      begin
        y := PopNum; x := PopNum;
        p := GS.CTM.Apply(x, y);
        GS.Path.MoveTo(p.X, p.Y);
      end;
    2, 4:
      begin
        y := PopNum; x := PopNum;
        if not GS.Path.HasCurrent then Err('nocurrentpoint');
        p := GS.Path.CurrentPoint;
        p1 := GS.CTM.ApplyVec(x, y);
        if Code = 2 then GS.Path.MoveTo(p.X + p1.X, p.Y + p1.Y) else GS.Path.LineTo(p.X + p1.X, p.Y + p1.Y);
      end;
    3:
      begin
        y := PopNum; x := PopNum;
        if not GS.Path.HasCurrent then Err('nocurrentpoint');
        p := GS.CTM.Apply(x, y);
        GS.Path.LineTo(p.X, p.Y);
      end;
    5, 6:
      begin
        y3 := PopNum; x3 := PopNum; y2 := PopNum; x2 := PopNum; y1 := PopNum; x1 := PopNum;
        if not GS.Path.HasCurrent then Err('nocurrentpoint');
        if Code = 5 then
        begin
          p1 := GS.CTM.Apply(x1, y1); p2 := GS.CTM.Apply(x2, y2); p3 := GS.CTM.Apply(x3, y3);
        end
        else
        begin
          p := GS.Path.CurrentPoint;
          p1 := GS.CTM.ApplyVec(x1, y1); p2 := GS.CTM.ApplyVec(x2, y2); p3 := GS.CTM.ApplyVec(x3, y3);
          p1.X := p1.X + p.X; p1.Y := p1.Y + p.Y;
          p2.X := p2.X + p.X; p2.Y := p2.Y + p.Y;
          p3.X := p3.X + p.X; p3.Y := p3.Y + p.Y;
        end;
        GS.Path.CubicTo(p1.X, p1.Y, p2.X, p2.Y, p3.X, p3.Y);
      end;
    7, 8:
      begin
        a2 := PopNum; a1 := PopNum; r := PopNum; y := PopNum; x := PopNum;
        ArcUser(x, y, r, a1, a2, Code = 7);
      end;
    9, 10:
      begin
        r := PopNum; y2 := PopNum; x2 := PopNum; y1 := PopNum; x1 := PopNum;
        if not CurPointUser(x, y) then Err('nocurrentpoint');
        d1x := x - x1; d1y := y - y1; d2x := x2 - x1; d2y := y2 - y1;
        l1 := Hypot(d1x, d1y); l2 := Hypot(d2x, d2y);
        if (l1 = 0) or (l2 = 0) or (r = 0) then
        begin
          p := GS.CTM.Apply(x1, y1);
          GS.Path.LineTo(p.X, p.Y);
          if Code = 10 then begin Push(RealObj(x1)); Push(RealObj(y1)); Push(RealObj(x1)); Push(RealObj(y1)); end;
          Exit;
        end;
        d1x := d1x / l1; d1y := d1y / l1; d2x := d2x / l2; d2y := d2y / l2;
        cosT := EnsureRange(d1x * d2x + d1y * d2y, -1, 1);
        th := ArcCos(cosT);
        if (th < 1e-9) or (Abs(th - Pi) < 1e-9) then
        begin
          p := GS.CTM.Apply(x1, y1);
          GS.Path.LineTo(p.X, p.Y);
          if Code = 10 then begin Push(RealObj(x1)); Push(RealObj(y1)); Push(RealObj(x1)); Push(RealObj(y1)); end;
          Exit;
        end;
        dist := r / Tan(th / 2);
        x2 := x1 + d2x * dist; y2 := y1 + d2y * dist;     // tangent points
        x3 := x1 + d1x * dist; y3 := y1 + d1y * dist;
        cr := r / Sin(th / 2);
        cx := (d1x + d2x); cy := (d1y + d2y);
        l1 := Hypot(cx, cy);
        cx := x1 + cx / l1 * cr; cy := y1 + cy / l1 * cr;
        sa := ArcTan2(y3 - cy, x3 - cx) * 180 / Pi;
        ea := ArcTan2(y2 - cy, x2 - cx) * 180 / Pi;
        // the arc turns the way the corner does
        ArcUser(cx, cy, r, sa, ea, (d1x * d2y - d1y * d2x) < 0);
        if Code = 10 then
        begin
          Push(RealObj(x3)); Push(RealObj(y3)); Push(RealObj(x2)); Push(RealObj(y2));
        end;
      end;
    11: GS.Path.Close;
    12:
      begin
        if not CurPointUser(x, y) then Err('nocurrentpoint');
        Push(RealObj(x)); Push(RealObj(y));
      end;
    13:
      begin
        GS.Path.Clear;
        if Length(GS.Clips) > 0 then GS.Path := GS.Clips[High(GS.Clips)].Path.Copy
        else
        begin
          inv := GS.CTM;
          GS.CTM := DefaultCTM;
          SetLength(rects, 4);
          rects[0] := 0; rects[1] := 0; rects[2] := PageW; rects[3] := PageH;
          RectsToPath(rects);
          GS.CTM := inv;
        end;
      end;
    14:
      begin
        if not GS.Path.Bounds(rc) then Err('nocurrentpoint');
        inv := GS.CTM.Invert;
        p := inv.Apply(rc.Left, rc.Top);
        x1 := p.X; y1 := p.Y; x2 := p.X; y2 := p.Y;
        for i := 1 to 3 do
        begin
          case i of
            1: p := inv.Apply(rc.Right, rc.Top);
            2: p := inv.Apply(rc.Right, rc.Bottom);
          else
            p := inv.Apply(rc.Left, rc.Bottom);
          end;
          x1 := Min(x1, p.X); y1 := Min(y1, p.Y); x2 := Max(x2, p.X); y2 := Max(y2, p.Y);
        end;
        Push(RealObj(x1)); Push(RealObj(y1)); Push(RealObj(x2)); Push(RealObj(y2));
      end;
    15: AddClipPath(frNonZero);
    16: AddClipPath(frEvenOdd);
    17:
      begin
        GS.Clips := nil;
        GS.ClipSerial := 0;
      end;
    18:
      begin
        rects := PopRects;
        GS.Path.Clear;
        RectsToPath(rects);
        AddClipPath(frNonZero);
        GS.Path.Clear;
      end;
    19: OpIgnore(4);
  end;
end;

// ------------------------------ painting -----------------------------------

procedure TPSInterp.OpPaint(Code: Integer);
var
  rects: TXVDoubles;
  savePath: TXVPath;
  saveCTM, m: TXVMatrix;
  o, o2, bb, pp: TPSObj;
  d: TPSDict;
  g, i, pt: Integer;
  avg: TXVColor;
  saveDoc, tmp: TXVDocument;
  saveGroups, saveSerial: Integer;
  saveDrew: Boolean;
  tile: TPSTile;
begin
  case Code of
    0: begin Emit(True, frNonZero); GS.Path.Clear; end;
    1: begin Emit(True, frEvenOdd); GS.Path.Clear; end;
    2: begin Emit(False, frNonZero); GS.Path.Clear; end;
    3:
      begin
        rects := PopRects;
        savePath := GS.Path;
        GS.Path := Default(TXVPath);
        RectsToPath(rects);
        Emit(True, frNonZero);
        GS.Path := savePath;
      end;
    4:
      begin
        saveCTM := GS.CTM;
        m := TXVMatrix.Identity;
        if (OSN > 1) and (Top^.K = okArray) and (Top^.Len = 6) and (Top(1)^.K in [okInt, okReal, okArray]) then
          m := MatrixOf(PopArr);
        rects := PopRects;
        savePath := GS.Path;
        GS.Path := Default(TXVPath);
        RectsToPath(rects);
        GS.CTM := XVMul(GS.CTM, m);
        Emit(False, frNonZero);
        GS.CTM := saveCTM;
        GS.Path := savePath;
      end;
    5:
      begin
        ShowPage;
        InitGraphics;
      end;
    6: DoImage(0);
    7: DoImage(1);
    8: DoImage(2);
    9:
      begin
        d := PopDict;
        g := ShadingGradient(d, GS.CTM, avg);
        savePath := GS.Path;
        GS.Path := Default(TXVPath);
        if DictGet(d, 'BBox', bb) and (bb.K = okArray) and (bb.Len >= 4) then
        begin
          SetLength(rects, 4);
          rects[0] := NumOf(ArrItem(bb, 0)); rects[1] := NumOf(ArrItem(bb, 1));
          rects[2] := NumOf(ArrItem(bb, 2)) - rects[0]; rects[3] := NumOf(ArrItem(bb, 3)) - rects[1];
          RectsToPath(rects);
        end
        else
          GS.Path.AddRect(-2, -2, PageW * K_PX + 4, PageH * K_PX + 4);
        i := GS.PatternPaint;
        avg := GS.Color;
        GS.PatternPaint := g;
        if (g >= 0) and (Length(Doc.Gradients[g].Stops) > 0) then
          GS.Color := Doc.Gradients[g].Stops[Length(Doc.Gradients[g].Stops) div 2].Color;
        Emit(True, frNonZero);
        GS.PatternPaint := i;
        GS.Color := avg;
        GS.Path := savePath;
      end;
    10:
      begin
        m := MatrixOf(PopArr);
        o := Pop;
        if o.K <> okDict then Err('typecheck');
        d := NewDict(o.D.Map.Count + 4);
        CopyDict(o.D, d);
        o2 := DictObj(d);
        pt := 1;
        if DictGet(d, 'PatternType', pp) then pt := Round(NumOf(pp));
        if pt = 2 then
        begin
          if DictGet(d, 'Shading', pp) and (pp.K = okDict) then
          begin
            g := ShadingGradient(pp.D, XVMul(GS.CTM, m), avg);
            DictPut(d, 'XVGradient', IntObj(g));
            DictPut(d, 'XVColor', IntObj(avg));
          end;
        end
        else
        begin
          // a tiling pattern: the cell is drawn once into its own document
          // (in pattern space); fills repeat it. Its first colour stands for
          // it where a single colour is needed.
          avg := $FF808080;
          if DictGet(d, 'PaintProc', pp) then
          begin
            saveDoc := Doc;
            tmp := TXVDocument.Create;
            Objs.Add(tmp);
            tile := Default(TPSTile);
            tile.Cell := tmp;
            tile.M := XVMul(GS.CTM, m);
            tile.BBox := XVRect(0, 0, 1, 1);
            if DictGet(d, 'BBox', bb) and (bb.K = okArray) and (bb.Len >= 4) then
              tile.BBox := XVRect(Min(NumOf(ArrItem(bb, 0)), NumOf(ArrItem(bb, 2))), Min(NumOf(ArrItem(bb, 1)),
                NumOf(ArrItem(bb, 3))), Max(NumOf(ArrItem(bb, 0)), NumOf(ArrItem(bb, 2))), Max(NumOf(ArrItem(bb, 1)),
                NumOf(ArrItem(bb, 3))));
            if DictGet(d, 'XStep', bb) then tile.XStep := NumOf(bb);
            if DictGet(d, 'YStep', bb) then tile.YStep := NumOf(bb);
            if DictGet(d, 'PaintType', bb) then tile.Uncoloured := NumOf(bb) = 2;
            saveGroups := OpenGroups;
            saveSerial := EmittedSerial;
            saveDrew := Drew;
            Doc := tmp;
            GSave;
            try
              GS.CTM := TXVMatrix.Identity;
              GS.Path.Clear;
              GS.Clips := nil;
              GS.ClipSerial := 0;
              GS.PatternTile := -1;
              GS.PatternPaint := -1;
              OpenGroups := 0;
              EmittedSerial := 0;
              // the cell is clipped by its box
              GS.Path.AddRect(tile.BBox.Left, tile.BBox.Top, tile.BBox.Width, tile.BBox.Height);
              AddClipPath(frNonZero);
              GS.Path.Clear;
              Push(o2);
              try
                Exec(pp);
              except
                on EPSError do ;
              end;
              ClosePageGroups;
              for i := 0 to tmp.Count - 1 do
                if tmp.Elements[i].Kind = ekPath then
                begin
                  if tmp.Elements[i].Fill.Kind <> pkNone then avg := tmp.Elements[i].Fill.Color
                  else avg := tmp.Elements[i].Stroke.Paint.Color;
                  Break;
                end
                else if tmp.Elements[i].Kind = ekText then
                begin
                  avg := tmp.Elements[i].Fill.Color;
                  Break;
                end;
            finally
              GRestore;
              Doc := saveDoc;
              OpenGroups := saveGroups;
              EmittedSerial := saveSerial;
              Drew := saveDrew;
            end;
            SetLength(Tiles, Length(Tiles) + 1);
            Tiles[High(Tiles)] := tile;
            DictPut(d, 'XVTile', IntObj(High(Tiles)));
          end;
          DictPut(d, 'XVColor', IntObj(avg));
        end;
        Push(o2);
      end;
    11:
      begin
        d := PopDict;
        GSave;
        try
          if DictGet(d, 'Matrix', pp) and (pp.K = okArray) then GS.CTM := XVMul(GS.CTM, MatrixOf(pp));
          if DictGet(d, 'BBox', bb) and (bb.K = okArray) and (bb.Len >= 4) then
          begin
            SetLength(rects, 4);
            rects[0] := NumOf(ArrItem(bb, 0)); rects[1] := NumOf(ArrItem(bb, 1));
            rects[2] := NumOf(ArrItem(bb, 2)) - rects[0]; rects[3] := NumOf(ArrItem(bb, 3)) - rects[1];
            GS.Path.Clear;
            RectsToPath(rects);
            AddClipPath(frNonZero);
            GS.Path.Clear;
          end;
          if DictGet(d, 'PaintProc', pp) then
          begin
            Push(DictObj(d));
            Exec(pp);
          end;
        finally
          GRestore;
        end;
      end;
    12: ;
  end;
end;

// ------------------------------ fonts and text -----------------------------

procedure TPSInterp.OpFont(Code: Integer);
var
  o, f, s, k, cat, inst, proc, disp, enc: TPSObj;
  ax, ay, cx, cy, sz: Double;
  ch: Integer;
  m: TXVMatrix;
  d: TPSDict;
  w: Double;
  p: TXVPoint;
  fam: string;
  b, it: Boolean;
  fm: TXVMatrix;
  u: Cardinal;
  key: string;
  nul: TPSObj;
begin
  nul := NullObj;
  case Code of
    0: Push(FindFont(Pop));
    1:
      begin
        sz := PopNum;
        f := Pop;
        Push(ScaledFont(f, TXVMatrix.Scale(sz, sz)));
      end;
    2:
      begin
        m := MatrixOf(PopArr);
        f := Pop;
        Push(ScaledFont(f, m));
      end;
    3:
      begin
        f := Pop;
        if f.K <> okDict then Err('typecheck');
        GS.Font := f;
      end;
    4, 29:
      begin
        if GS.Font.K <> okDict then GS.Font := ScaledFont(FindFont(NameObj('Courier', False)), TXVMatrix.Scale(10, 10));
        Push(GS.Font);
      end;
    5:
      begin
        o := Pop;
        k := Pop;
        f := FindFont(k);
        if o.K = okArray then GS.Font := ScaledFont(f, MatrixOf(o))
        else GS.Font := ScaledFont(f, TXVMatrix.Scale(NumOf(o), NumOf(o)));
      end;
    6:
      begin
        f := Pop;
        k := Pop;
        if f.K <> okDict then Err('typecheck');
        if not f.D.Map.ContainsKey('FontName') then DictPut(f.D, 'FontName', NameObj(KeyOf(k), False));
        DictPut(f.D, 'FID', IntObj(Objs.Count));
        DictPutK(FontDir, k, f);
        if Debug then WriteLn(StdErr, 'definefont ', KeyOf(k), ' type ', CvsText(DictGetDef(f.D, 'FontType')), ' CharStrings ', f.D.Map.ContainsKey('CharStrings'), ' Private ', f.D.Map.ContainsKey('Private'), ' sfnts ', f.D.Map.ContainsKey('sfnts'));
        Push(f);
      end;
    7:
      begin
        k := Pop;
        FontDir.Map.Remove(KeyOf(k));
        FontDir.Keys.Remove(KeyOf(k));
      end;
    8: begin s := PopStr; ShowText(s, 0, 0, 0, 0, 0, -1, nul, nul); end;
    9: begin s := PopStr; ay := PopNum; ax := PopNum; ShowText(s, 1, ax, ay, 0, 0, -1, nul, nul); end;
    10: begin s := PopStr; ch := PopInt; cy := PopNum; cx := PopNum; ShowText(s, 2, 0, 0, cx, cy, ch, nul, nul); end;
    11:
      begin
        s := PopStr; ay := PopNum; ax := PopNum; ch := PopInt; cy := PopNum; cx := PopNum;
        ShowText(s, 3, ax, ay, cx, cy, ch, nul, nul);
      end;
    12, 16: begin s := PopStr; proc := Pop; ShowText(s, 0, 0, 0, 0, 0, -1, proc, nul); end;
    13, 14, 15:
      begin
        disp := Pop;
        s := PopStr;
        if Code = 14 then ShowText(s, 0, 0, 0, 0, 0, -1, nul, nul)
        else ShowText(s, Code - 8, 0, 0, 0, 0, -1, nul, disp);
      end;
    17: ShowGlyphName(StrOf(Pop));
    18:
      begin
        s := PopStr;
        if GS.Font.K <> okDict then Err('invalidfont');
        FontInfo(GS.Font, fam, b, it, fm);
        w := TextWidth(GS.Font, s);
        p := fm.ApplyVec(w, 0);
        Push(RealObj(p.X)); Push(RealObj(p.Y));
      end;
    19:
      begin
        Pop;
        s := PopStr;
        ShowText(s, 9, 0, 0, 0, 0, -1, nul, nul);
      end;
    20, 21, 22:
      begin
        case Code of
          20: begin OpIgnore(4); Pop; w := PopNum; end;
          21: begin OpIgnore(8); Pop; w := PopNum; end;
        else
          begin Pop; w := PopNum; end;
        end;
        if CharFont <> nil then DictPut(CharFont, 'XVLastWidth', RealObj(w));
      end;
    23:
      begin
        cat := Pop;
        k := Pop;
        key := StrOf(cat);
        if key = 'Font' then Push(FindFont(k))
        else if (key = 'Encoding') and (KeyOf(k) = 'StandardEncoding') then Push(StdEnc)
        else if (key = 'Encoding') and (KeyOf(k) = 'ISOLatin1Encoding') then Push(IsoEnc)
        else if DictGet(ResDict, key, o) and (o.K = okDict) and DictGet(o.D, KeyOf(k), inst) then Push(inst)
        else if (key = 'Category') and DictGet(ResDict, KeyOf(k), o) then Push(o)
        else
        begin
          CurCmd := KeyOf(k);
          Err('undefinedresource');
        end;
      end;
    24:
      begin
        cat := Pop;
        inst := Pop;
        k := Pop;
        key := StrOf(cat);
        if key = 'Font' then
        begin
          Push(k);
          Push(inst);
          OpFont(6);
          Exit;
        end;
        if not (DictGet(ResDict, key, o) and (o.K = okDict)) then
        begin
          o := DictObj(NewDict(8));
          DictPut(ResDict, key, o);
        end;
        DictPutK(o.D, k, inst);
        Push(inst);
      end;
    25:
      begin
        cat := Pop;
        k := Pop;
        if DictGet(ResDict, StrOf(cat), o) and (o.K = okDict) then
        begin
          o.D.Map.Remove(KeyOf(k));
          o.D.Keys.Remove(KeyOf(k));
        end;
      end;
    26:
      begin
        cat := Pop;
        k := Pop;
        key := StrOf(cat);
        if (key = 'Font') or ((key = 'Encoding') and ((KeyOf(k) = 'StandardEncoding') or (KeyOf(k) = 'ISOLatin1Encoding'))) or
          (DictGet(ResDict, key, o) and (o.K = okDict) and o.D.Map.ContainsKey(KeyOf(k))) then
        begin
          Push(IntObj(1));
          Push(IntObj(0));
          Push(BoolObj(True));
        end
        else Push(BoolObj(False));
      end;
    27: OpIgnore(4);
    28:
      begin
        k := Pop;
        if KeyOf(k) = 'ISOLatin1Encoding' then Push(IsoEnc) else Push(StdEnc);
      end;
    30:
      begin
        Pop; Pop;
        k := Pop;
        Push(FindFont(k));
      end;
  end;
end;

// ------------------------------ files --------------------------------------

procedure TPSInterp.OpFile(Code: Integer);
var
  o, s, nm, fo: TPSObj;
  f, src, res: TPSFile;
  params: TPSDict;
  n, i, h, v, c, total: Integer;
  name: string;
  cnt: Double;
  eod: TPSObj;
  buf: TBytes;
  save: Integer;
begin
  case Code of
    0: Push(FileObj(CurFile));
    1:
      begin
        o := Pop;
        if o.K <> okFile then Err('typecheck');
        c := FileByte(o.F);
        if c >= 0 then begin Push(IntObj(c)); Push(BoolObj(True)); end
        else Push(BoolObj(False));
      end;
    2:
      begin
        s := PopStr;
        o := Pop;
        if o.K <> okFile then Err('typecheck');
        f := o.F;
        if f.Closed then n := 0 else n := Max(0, Min(s.Len, Length(f.Data) - f.Pos));
        if n > 0 then Move(f.Data[f.Pos], s.S.Data[s.Off], n);
        Inc(f.Pos, n);
        Push(SubStr(s, 0, n));
        Push(BoolObj(n = s.Len));
      end;
    3:
      begin
        s := PopStr;
        o := Pop;
        if o.K <> okFile then Err('typecheck');
        f := o.F;
        n := 0;
        h := -1;
        while (n < s.Len) and not f.Closed and (f.Pos < Length(f.Data)) do
        begin
          c := f.Data[f.Pos];
          Inc(f.Pos);
          case Chr(c) of
            '0'..'9': v := c - 48;
            'a'..'f': v := c - 87;
            'A'..'F': v := c - 55;
          else
            Continue;
          end;
          if h < 0 then h := v
          else
          begin
            s.S.Data[s.Off + n] := h * 16 + v;
            Inc(n);
            h := -1;
          end;
        end;
        Push(SubStr(s, 0, n));
        Push(BoolObj(n = s.Len));
      end;
    4:
      begin
        s := PopStr;
        o := Pop;
        if o.K <> okFile then Err('typecheck');
        f := o.F;
        n := 0;
        c := -1;
        while not f.Closed and (f.Pos < Length(f.Data)) do
        begin
          c := f.Data[f.Pos];
          Inc(f.Pos);
          if c = 10 then Break;
          if c = 13 then
          begin
            if (f.Pos < Length(f.Data)) and (f.Data[f.Pos] = 10) then Inc(f.Pos);
            c := 10;
            Break;
          end;
          if n >= s.Len then Err('rangecheck');
          s.S.Data[s.Off + n] := c;
          Inc(n);
          c := -1;
        end;
        Push(SubStr(s, 0, n));
        Push(BoolObj(c = 10));
      end;
    5:
      begin
        Pop;
        nm := Pop;
        name := StrOf(nm);
        if (name <> '') and (name[1] = '%') then
        begin
          f := TPSFile.Create;
          Objs.Add(f);
          Push(FileObj(f));
        end
        else
        begin
          CurCmd := name;
          Err('undefinedfilename');
        end;
      end;
    6:
      begin
        nm := Pop;
        name := StrOf(nm);
        params := nil;
        if name = 'SubFileDecode' then
        begin
          if (OSN > 1) and (Top^.K = okString) and IsNum(Top(1)^) then
          begin
            eod := Pop;
            cnt := PopNum;
            params := NewDict(2);
            DictPut(params, 'EODCount', RealObj(cnt));
            DictPut(params, 'EODString', eod);
          end
          else if (OSN > 0) and (Top^.K = okDict) then params := PopDict;
        end
        else if (OSN > 0) and (Top^.K = okDict) then params := PopDict;
        o := Pop;
        case o.K of
          okFile: src := o.F;
          okString: src := TempFile(o);
          okArray:
            begin
              // a procedure: its strings, until an empty one
              src := TPSFile.Create;
              Objs.Add(src);
              buf := nil;
              total := 0;
              for i := 1 to 1000000 do
              begin
                save := OSN;
                Exec(o);
                if OSN <= save then Break;
                s := Pop;
                OSN := save;
                if (s.K <> okString) or (s.Len = 0) then Break;
                SetLength(buf, total + s.Len);
                Move(s.S.Data[s.Off], buf[total], s.Len);
                Inc(total, s.Len);
              end;
              src.Data := buf;
            end;
        else
          begin
            Err('typecheck');
            src := nil;
          end;
        end;
        res := MakeFilter(src, name, params);
        Push(FileObj(res));
      end;
    7:
      begin
        o := Pop;
        if o.K = okFile then o.F.Closed := True;
      end;
    8:
      begin
        o := Pop;
        if o.K = okFile then f := o.F
        else if o.K = okString then f := TempFile(o)
        else begin Err('typecheck'); f := nil; end;
        res := DecodeEexec(f);
        SetLength(DS, Length(DS) + 1);
        DS[High(DS)] := SysDict;
        n := Length(DS);
        try
          RunFile(res);
        finally
          if (Length(DS) >= n) and (DS[n - 1] = SysDict) then
          begin
            for i := n - 1 to High(DS) - 1 do DS[i] := DS[i + 1];
            SetLength(DS, Length(DS) - 1);
          end;
        end;
      end;
    9: Pop;
    10:
      begin
        o := Pop;
        if o.K = okFile then Push(BoolObj(not o.F.Closed))
        else Push(BoolObj(False));
      end;
    11:
      begin
        o := Pop;
        if o.K <> okFile then Err('typecheck');
        Push(IntObj(o.F.Pos));
      end;
    12:
      begin
        n := PopInt;
        o := Pop;
        if o.K <> okFile then Err('typecheck');
        o.F.Pos := EnsureRange(n, 0, Length(o.F.Data));
      end;
    13: Pop;
  end;
end;

// ------------------------------ device and system --------------------------

procedure TPSInterp.OpMisc(Code: Integer);
var
  d: TPSDict;
  o, a: TPSObj;
  i: Integer;
begin
  case Code of
    0:
      begin
        d := PopDict;
        if DictGet(d, 'PageSize', o) and (o.K = okArray) and (o.Len >= 2) and not (IsEPS and BBoxSet) then
        begin
          SetPage(0, 0, NumOf(ArrItem(o, 0)), NumOf(ArrItem(o, 1)));
          PageSizeSet := True;
        end;
        InitGraphics;
      end;
    1:
      begin
        d := NewDict(8);
        a := NewArr(2);
        ArrSet(a, 0, RealObj(PageW)); ArrSet(a, 1, RealObj(PageH));
        DictPut(d, 'PageSize', a);
        a := NewArr(2);
        ArrSet(a, 0, RealObj(72)); ArrSet(a, 1, RealObj(72));
        DictPut(d, 'HWResolution', a);
        DictPut(d, 'ImagingBBox', NullObj);
        DictPut(d, 'Orientation', IntObj(0));
        DictPut(d, 'PageCount', IntObj(Page));
        DictPut(d, 'Policies', DictObj(NewDict(1)));
        DictPut(d, 'InputAttributes', DictObj(NewDict(1)));
        DictPut(d, 'OutputDevice', NameObj('pdfwrite', False));
        Push(DictObj(d));
      end;
    2: Push(StrObj('3010'));
    3: Push(IntObj(3));
    4: Push(StrObj('XelVectors'));
    5: Push(IntObj(1));
    6: Push(IntObj(0));
    7, 8: begin Inc(Clock); Push(IntObj(Clock)); end;
    9: begin Push(IntObj(0)); Push(IntObj(0)); Push(IntObj(10000000)); end;
    10, 11: Push(BoolObj(False));
    12, 17, 18:
      begin
        o := NewArr(0);
        o.X := True;
        Push(o);
      end;
    13:
      begin
        Push(RealObj(60)); Push(RealObj(0));
        o := NewArr(0); o.X := True;
        Push(o);
      end;
    14:
      begin
        d := NewDict(2);
        DictPut(d, 'HalftoneType', IntObj(1));
        Push(DictObj(d));
      end;
    15, 22, 23: Push(DictObj(NewDict(2)));
    16: Push(RealObj(0.02));
    19:
      for i := 1 to 4 do
      begin
        o := NewArr(0); o.X := True;
        Push(o);
      end;
    20: for i := 1 to 7 do Push(IntObj(0));
    21:
      begin
        o := Default(TPSObj);
        o.K := okMark;
        Push(o);
        Push(IntObj(0));
        Push(IntObj(0));
      end;
    24: begin Pop; Push(DictObj(NewDict(2))); end;
    25: begin Pop; Push(IntObj(-1)); end;
    26, 27: OpStack(9);
    28: begin Pop; Pop; Push(BoolObj(False)); end;
    29: begin o := Pop; Push(o); Push(BoolObj(False)); end;
    30: begin Pop; Push(BoolObj(False)); end;
    31: ;
  end;
end;

procedure TPSInterp.OpPrint(Code: Integer);
var i: Integer;
begin
  if Code <= 2 then
  begin
    if Debug then WriteLn(StdErr, '> ', CvsText(Pop)) else Pop;
  end
  else if Debug then
    for i := OSN - 1 downto 0 do WriteLn(StdErr, '  ', CvsText(OS[i]), ' (', Ord(OS[i].K), ')');
end;

// ------------------------------ set-up -------------------------------------

procedure TPSInterp.Init;
var
  i: Integer;
  e: TPSObj;

  procedure Ign(const Names: array of string; N: Integer);
  var j: Integer;
  begin
    for j := 0 to High(Names) do AddOp(Names[j], OpIgnore, N);
  end;

begin
  SysDict := NewDict(600);
  UserDict := NewDict(200);
  GlobalDict := NewDict(50);
  StatusDict := NewDict(20);
  ErrorDict := NewDict(40);
  DError := NewDict(10);
  FontDir := NewDict(50);
  ResDict := NewDict(20);
  InternalDict := NewDict(10);
  SetLength(DS, 3);
  DS[0] := SysDict;
  DS[1] := GlobalDict;
  DS[2] := UserDict;

  AddOps(['pop', 'exch', 'dup', 'copy', 'index', 'roll', 'clear', 'count', 'mark', 'cleartomark', 'counttomark',
    '[', ']', '<<', '>>'], OpStack);
  AddOps(['add', 'sub', 'mul', 'div', 'idiv', 'mod', 'neg', 'abs', 'ceiling', 'floor', 'round', 'truncate', 'sqrt',
    'atan', 'cos', 'sin', 'exp', 'ln', 'log', 'rand', 'srand', 'rrand', 'cvi', 'cvr', 'bitshift'], OpArith);
  AddOps(['eq', 'ne', 'gt', 'ge', 'lt', 'le', 'and', 'or', 'xor', 'not'], OpRel);
  AddOps(['exec', 'if', 'ifelse', 'for', 'repeat', 'loop', 'exit', 'forall', 'stop', 'stopped', 'countexecstack',
    'execstack', 'quit', 'start'], OpControl);
  AddOp('superexec', OpControl, 0);
  AddOps(['type', 'cvlit', 'cvx', 'xcheck', 'executeonly', 'noaccess', 'readonly', 'rcheck', 'wcheck', 'cvn', 'cvs',
    'cvrs', 'bind', 'gcheck'], OpType);
  AddOps(['dict', 'begin', 'end', 'def', 'load', 'store', 'known', 'where', 'currentdict', 'countdictstack',
    'dictstack', 'undef', 'maxlength', 'cleardictstack', 'currentglobal', 'setglobal', 'setpacking',
    'currentpacking', 'array', 'packedarray', 'aload', 'astore', 'string', 'internaldict'], OpDict);
  AddOps(['length', 'get', 'put', 'getinterval', 'putinterval', 'search', 'anchorsearch', 'token'], OpString);
  AddOps(['gsave', 'grestore', 'grestoreall', 'save', 'restore', 'setlinewidth', 'currentlinewidth', 'setlinecap',
    'currentlinecap', 'setlinejoin', 'currentlinejoin', 'setmiterlimit', 'currentmiterlimit', 'setdash',
    'currentdash', 'setflat', 'currentflat', 'setgray', 'setrgbcolor', 'sethsbcolor', 'setcmykcolor', 'currentgray',
    'currentrgbcolor', 'currenthsbcolor', 'currentcmykcolor', 'setcolorspace', 'setcolor', 'currentcolorspace',
    'currentcolor', 'initgraphics', 'setpattern', 'gstate', 'currentgstate', 'setgstate'], OpGState);
  AddOps(['matrix', 'initmatrix', 'identmatrix', 'defaultmatrix', 'currentmatrix', 'setmatrix', 'translate', 'scale',
    'rotate', 'concat', 'concatmatrix', 'transform', 'itransform', 'dtransform', 'idtransform', 'invertmatrix'],
    OpMatrix);
  AddOps(['newpath', 'moveto', 'rmoveto', 'lineto', 'rlineto', 'curveto', 'rcurveto', 'arc', 'arcn', 'arct', 'arcto',
    'closepath', 'currentpoint', 'clippath', 'pathbbox', 'clip', 'eoclip', 'initclip', 'rectclip', 'pathforall'],
    OpPath);
  AddOps(['fill', 'eofill', 'stroke', 'rectfill', 'rectstroke', 'showpage', 'image', 'imagemask', 'colorimage',
    'shfill', 'makepattern', 'execform', 'erasepage'], OpPaint);
  AddOps(['findfont', 'scalefont', 'makefont', 'setfont', 'currentfont', 'selectfont', 'definefont', 'undefinefont',
    'show', 'ashow', 'widthshow', 'awidthshow', 'kshow', 'xshow', 'yshow', 'xyshow', 'cshow', 'glyphshow',
    'stringwidth', 'charpath', 'setcachedevice', 'setcachedevice2', 'setcharwidth', 'findresource',
    'defineresource', 'undefineresource', 'resourcestatus', 'resourceforall', 'findencoding', 'rootfont',
    'composefont'], OpFont);
  AddOps(['currentfile', 'read', 'readstring', 'readhexstring', 'readline', 'file', 'filter', 'closefile', 'eexec',
    'run', 'status', 'fileposition', 'setfileposition', 'resetfile'], OpFile);
  AddOps(['setpagedevice', 'currentpagedevice', 'version', 'languagelevel', 'product', 'revision', 'serialnumber',
    'realtime', 'usertime', 'vmstatus', 'currentoverprint', 'currentstrokeadjust', 'currenttransfer',
    'currentscreen', 'currenthalftone', 'currentcolorrendering', 'currentsmoothness', 'currentblackgeneration',
    'currentundercolorremoval', 'currentcolortransfer', 'cachestatus', 'currentcacheparams', 'currentuserparams',
    'currentsystemparams', 'currentdevparams', 'bytesavailable', 'setcacheparams', 'setucacheparams', 'startjob',
    'findcolorrendering', 'checkpassword', 'ucache'], OpMisc);
  Ign(['nulldevice', 'flush', 'prompt', 'executive', 'copypage', 'flattenpath', 'reversepath',
    'strokepath', 'settrapzone', 'handleerror', 'initviewclip', 'eoviewclip', 'viewclip'], 0);
  Ign(['setstrokeadjust', 'setoverprint', 'sethalftone', 'settransfer', 'setblackgeneration', 'setundercolorremoval',
    'setsmoothness', 'setcolorrendering', 'setcachelimit', 'setvmthreshold', 'vmreclaim', 'echo', 'setjobtimeout',
    'setuserparams', 'setsystemparams', 'flushfile', 'deletefile', 'setobjectformat',
    'setshared', 'settrapparams', 'exitserver', 'setdistillerparams', 'setoverprintmode', 'undefineuserobject',
    'setcolorscreen_', 'setblendmode', 'setopacityalpha', 'setshapealpha'], 1);
  Ign(['writestring', 'write', 'writehexstring', 'renamefile', 'setdevparams', 'sethalftonephase',
    'defineuserobject'], 2);
  AddOps(['print', '=', '==', 'pstack', 'stack'], OpPrint);
  Ign(['setscreen'], 3);
  Ign(['setcolortransfer'], 4);
  Ign(['setcolorscreen'], 12);

  DictPut(SysDict, 'systemdict', DictObj(SysDict));
  DictPut(SysDict, 'userdict', DictObj(UserDict));
  DictPut(SysDict, 'globaldict', DictObj(GlobalDict));
  DictPut(SysDict, 'statusdict', DictObj(StatusDict));
  DictPut(SysDict, 'errordict', DictObj(ErrorDict));
  DictPut(SysDict, '$error', DictObj(DError));
  DictPut(SysDict, 'FontDirectory', DictObj(FontDir));
  DictPut(SysDict, 'GlobalFontDirectory', DictObj(FontDir));
  DictPut(SysDict, 'SharedFontDirectory', DictObj(FontDir));
  DictPut(SysDict, 'null', NullObj);
  DictPut(SysDict, 'true', BoolObj(True));
  DictPut(SysDict, 'false', BoolObj(False));
  DictPut(DError, 'newerror', BoolObj(False));
  DictPut(DError, 'errorname', NullObj);
  DictPut(DError, 'command', NullObj);
  DictPut(DError, 'recordstacks', BoolObj(False));

  // the standard encodings
  StdEnc := NewArr(256);
  IsoEnc := NewArr(256);
  for i := 0 to 255 do
  begin
    StdEnc.A.Items[i] := NameObj('.notdef', False);
    IsoEnc.A.Items[i] := NameObj('.notdef', False);
  end;
  for i := 32 to 126 do
  begin
    StdEnc.A.Items[i] := NameObj(ASCII_NAMES[i], False);
    IsoEnc.A.Items[i] := NameObj(ASCII_NAMES[i], False);
  end;
  IsoEnc.A.Items[45] := NameObj('hyphen', False);
  for i := 0 to High(STD_HIGH) do StdEnc.A.Items[STD_HIGH[i].C] := NameObj(STD_HIGH[i].N, False);
  for i := 160 to 255 do IsoEnc.A.Items[i] := NameObj(ISO_NAMES[i], False);
  IsoEnc.A.Items[144] := NameObj('dotlessi', False);
  IsoEnc.A.Items[145] := NameObj('grave', False);
  IsoEnc.A.Items[146] := NameObj('acute', False);
  IsoEnc.A.Items[147] := NameObj('circumflex', False);
  IsoEnc.A.Items[148] := NameObj('tilde', False);
  IsoEnc.A.Items[149] := NameObj('macron', False);
  IsoEnc.A.Items[150] := NameObj('breve', False);
  IsoEnc.A.Items[151] := NameObj('dotaccent', False);
  IsoEnc.A.Items[152] := NameObj('dieresis', False);
  IsoEnc.A.Items[154] := NameObj('ring', False);
  IsoEnc.A.Items[155] := NameObj('cedilla', False);
  IsoEnc.A.Items[157] := NameObj('hungarumlaut', False);
  IsoEnc.A.Items[158] := NameObj('ogonek', False);
  IsoEnc.A.Items[159] := NameObj('caron', False);
  DictPut(SysDict, 'StandardEncoding', StdEnc);
  DictPut(SysDict, 'ISOLatin1Encoding', IsoEnc);
end;

procedure TPSInterp.Prescan(const D: TBytes);
var
  s, line: string;
  n, p, q: Integer;
  a: TStringArray;
  hires: Boolean;

  function FindBox(const Txt, Tag: string; FromEnd: Boolean): Boolean;
  var i, j: Integer; t: string;
  begin
    Result := False;
    if FromEnd then
    begin
      i := 0;
      j := Pos(Tag, Txt);
      while j > 0 do begin i := j; j := Pos(Tag, Txt, j + 1); end;
    end
    else i := Pos(Tag, Txt);
    if i = 0 then Exit;
    j := i + Length(Tag);
    while (j <= Length(Txt)) and not (Txt[j] in [#10, #13]) do Inc(j);
    t := Trim(Copy(Txt, i + Length(Tag), j - i - Length(Tag)));
    if Pos('atend', t) > 0 then Exit;
    a := t.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
    if Length(a) < 4 then Exit;
    BLLX := XVStrToFloat(a[0]); BLLY := XVStrToFloat(a[1]); BURX := XVStrToFloat(a[2]); BURY := XVStrToFloat(a[3]);
    Result := (BURX > BLLX) and (BURY > BLLY);
  end;

begin
  n := Min(Length(D), 65536);
  SetLength(s, n);
  if n > 0 then Move(D[0], s[1], n);
  p := Pos(#10, s);
  q := Pos(#13, s);
  if (q > 0) and ((p = 0) or (q < p)) then p := q;
  if p = 0 then p := Length(s) + 1;
  line := Copy(s, 1, p - 1);
  IsEPS := Pos('EPSF', line) > 0;
  hires := FindBox(s, '%%HiResBoundingBox:', False);
  BBoxSet := hires or FindBox(s, '%%BoundingBox:', False);
  if not BBoxSet then
  begin
    // (atend): the trailer
    n := Min(Length(D), 65536);
    SetLength(s, n);
    if n > 0 then Move(D[Length(D) - n], s[1], n);
    BBoxSet := FindBox(s, '%%HiResBoundingBox:', True) or FindBox(s, '%%BoundingBox:', True);
  end;
  NPages := 0;
  p := Pos('%%Pages:', s);
  if p > 0 then NPages := StrToIntDef(Trim(Copy(s, p + 8, Pos(#10, Copy(s, p, 200)) - 9)), 0);
  p := Pos('%%Title:', s);
  if p > 0 then
  begin
    q := p + 8;
    while (q <= Length(s)) and not (s[q] in [#10, #13]) do Inc(q);
    Doc.Title := Trim(Copy(s, p + 8, q - p - 8));
    if (Doc.Title <> '') and (Doc.Title[1] = '(') then Doc.Title := Copy(Doc.Title, 2, Length(Doc.Title) - 2);
  end;
end;

procedure TPSInterp.Run(const Data: TBytes);
var
  d: TBytes;
  ofs, len_, errs: Integer;
  done: Boolean;
begin
  d := Data;
  // DOS EPS binary: the PostScript section
  if (Length(d) > 30) and (d[0] = $C5) and (d[1] = $D0) and (d[2] = $D3) and (d[3] = $C6) then
  begin
    ofs := d[4] or (d[5] shl 8) or (d[6] shl 16) or (d[7] shl 24);
    len_ := d[8] or (d[9] shl 8) or (d[10] shl 16) or (d[11] shl 24);
    if (ofs > 0) and (ofs < Length(d)) then
    begin
      if (len_ <= 0) or (ofs + len_ > Length(d)) then len_ := Length(d) - ofs;
      d := Copy(d, ofs, len_);
    end;
  end;
  if (Length(d) > 0) and (d[0] = 4) then d := Copy(d, 1, MaxInt);
  MainFile := TPSFile.Create;
  Objs.Add(MainFile);
  MainFile.Data := d;
  Prescan(d);
  Init;
  TargetPage := Max(0, Doc.LoadPage);
  if BBoxSet and IsEPS then SetPage(BLLX, BLLY, BURX, BURY)
  else if BBoxSet then SetPage(0, 0, Max(BURX, 1), Max(BURY, 1))
  else SetPage(0, 0, 612, 792);
  if not IsEPS then Doc.Background := $FFFFFFFF;
  InitGraphics;
  EmittedSerial := 0;
  errs := 0;
  done := False;
  repeat
    try
      RunFile(MainFile);
      done := True;
    except
      on EPSQuit do done := True;
      on E: Exception do
      begin
        Inc(errs);
        if Debug then
        begin
          if E is EPSError then WriteLn(StdErr, 'PS error: ', EPSError(E).ErrName, ' in ', CurCmd, '/', Ops[CurOp].Name, ' at ', MainFile.Pos)
          else WriteLn(StdErr, 'PS exception: ', E.ClassName, ' ', E.Message, ' in ', CurCmd, ' at ', MainFile.Pos);
        end;
        if errs > 100 then done := True;
        Depth := 0;
      end;
    end;
  until done or (MainFile.Pos >= Length(MainFile.Data)) or MainFile.Closed;
  ClosePageGroups;
  if NPages > 0 then Doc.PageCount := NPages else Doc.PageCount := Max(1, Page + Ord(Drew));
end;
