// XelVectors - PostScript interpreter: glyph outlines of the fonts a file
// carries. Type 1 fonts (charstrings, eexec encrypted, with subroutines,
// flex, hint replacement and seac accented characters) and Type 42 fonts
// (TrueType outlines in the sfnts strings). Included by XVReadPS.pas.

// charstring / subroutine decryption; LenIV < 0: not encrypted
function T1Decrypt(const S: TPSObj; LenIV: Integer): TBytes;
var
  i: Integer;
  r: Word;
  c: Byte;
begin
  Result := nil;
  if (S.K <> okString) or (S.Len <= 0) then Exit;
  SetLength(Result, S.Len);
  Move(S.S.Data[S.Off], Result[0], S.Len);
  if LenIV < 0 then Exit;
  r := 4330;
  for i := 0 to High(Result) do
  begin
    c := Result[i];
    Result[i] := c xor (r shr 8);
    r := Word((c + r) * 52845 + 22719);
  end;
  if LenIV >= Length(Result) then Result := nil
  else Result := Copy(Result, LenIV, MaxInt);
end;

function TPSInterp.Type1Glyph(FD: TPSDict; const Name: string; out G: TPSGlyph): Boolean;
var
  cstr, priv, subrs, o: TPSObj;
  lenIV, sp, psp, nflex, i: Integer;
  st: array[0..63] of Double;
  pss: array[0..31] of Double;
  cx, cy, ox, oy: Double;
  flexing, ended: Boolean;
  flex: array[0..15] of TXVPoint;

  procedure Push(V: Double);
  begin
    if sp <= High(st) then
    begin
      st[sp] := V;
      Inc(sp);
    end;
  end;

  function Arg(I: Integer): Double;
  begin
    if (I >= 0) and (I < sp) then Result := st[I] else Result := 0;
  end;

  procedure EnsureMove;
  begin
    if not G.Path.HasCurrent then G.Path.MoveTo(cx, cy);
  end;

  procedure LineBy(DX, DY: Double);
  begin
    EnsureMove;
    cx := cx + DX;
    cy := cy + DY;
    G.Path.LineTo(cx, cy);
  end;

  procedure CurveBy(DX1, DY1, DX2, DY2, DX3, DY3: Double);
  var x1, y1, x2, y2: Double;
  begin
    EnsureMove;
    x1 := cx + DX1; y1 := cy + DY1;
    x2 := x1 + DX2; y2 := y1 + DY2;
    cx := x2 + DX3; cy := y2 + DY3;
    G.Path.CubicTo(x1, y1, x2, y2, cx, cy);
  end;

  procedure MoveBy(DX, DY: Double);
  begin
    cx := cx + DX;
    cy := cy + DY;
    if not flexing then G.Path.MoveTo(cx, cy);
  end;

  function Charstring(const GlyphName: string; out Code: TBytes): Boolean;
  var s: TPSObj;
  begin
    Result := (cstr.K = okDict) and DictGet(cstr.D, GlyphName, s) and (s.K = okString);
    if Result then Code := T1Decrypt(s, lenIV);
  end;

  procedure Run(const Code: TBytes; Depth: Integer; TopLevel: Boolean);
  var
    p, v, n, k, oth: Integer;
    b: Byte;
    sub, base, accent: TBytes;
    args: array[0..15] of Double;
    asb, adx, ady: Double;
    bname, aname: string;
    soX, soY: Double;
  begin
    if (Depth > 12) or ended then Exit;
    p := 0;
    while (p < Length(Code)) and not ended do
    begin
      b := Code[p];
      Inc(p);
      if b >= 32 then
      begin
        if b <= 246 then Push(b - 139)
        else if b <= 250 then
        begin
          if p < Length(Code) then Push((b - 247) * 256 + Code[p] + 108);
          Inc(p);
        end
        else if b <= 254 then
        begin
          if p < Length(Code) then Push(-(b - 251) * 256 - Code[p] - 108);
          Inc(p);
        end
        else
        begin
          if p + 3 < Length(Code) then
            Push(Int32((Cardinal(Code[p]) shl 24) or (Cardinal(Code[p + 1]) shl 16) or (Cardinal(Code[p + 2]) shl 8) or
              Code[p + 3]));
          Inc(p, 4);
        end;
        Continue;
      end;
      case b of
        1, 3: sp := 0;                                   // hstem, vstem
        4: begin MoveBy(0, Arg(sp - 1)); sp := 0; end;   // vmoveto
        5: begin LineBy(Arg(0), Arg(1)); sp := 0; end;   // rlineto
        6: begin LineBy(Arg(0), 0); sp := 0; end;        // hlineto
        7: begin LineBy(0, Arg(0)); sp := 0; end;        // vlineto
        8: begin CurveBy(Arg(0), Arg(1), Arg(2), Arg(3), Arg(4), Arg(5)); sp := 0; end;
        9: begin G.Path.Close; sp := 0; end;             // closepath
        10:
          begin
            // callsubr
            v := Trunc(Arg(sp - 1));
            if sp > 0 then Dec(sp);
            if (subrs.K = okArray) and (v >= 0) and (v < subrs.Len) then
            begin
              sub := T1Decrypt(ArrItem(subrs, v), lenIV);
              Run(sub, Depth + 1, TopLevel);
            end;
          end;
        11: Exit;                                         // return
        13:
          begin
            // hsbw: side bearing and width
            cx := ox + Arg(0);
            cy := oy;
            if TopLevel then G.Width := Arg(1);
            sp := 0;
          end;
        14: begin ended := True; Exit; end;               // endchar
        21: begin MoveBy(Arg(0), Arg(1)); sp := 0; end;  // rmoveto
        22: begin MoveBy(Arg(sp - 1), 0); sp := 0; end;  // hmoveto
        30: begin CurveBy(0, Arg(0), Arg(1), Arg(2), Arg(3), 0); sp := 0; end;   // vhcurveto
        31: begin CurveBy(Arg(0), 0, Arg(1), Arg(2), 0, Arg(3)); sp := 0; end;   // hvcurveto
        12:
          begin
            if p >= Length(Code) then Exit;
            b := Code[p];
            Inc(p);
            case b of
              0, 1, 2: sp := 0;                           // dotsection, vstem3, hstem3
              6:
                begin
                  // seac: base character, accent moved by (adx - asb, ady)
                  asb := Arg(0); adx := Arg(1); ady := Arg(2);
                  bname := StrOf(ArrItem(StdEnc, EnsureRange(Trunc(Arg(3)), 0, 255)));
                  aname := StrOf(ArrItem(StdEnc, EnsureRange(Trunc(Arg(4)), 0, 255)));
                  sp := 0;
                  soX := ox; soY := oy;
                  if Charstring(bname, base) then
                  begin
                    ended := False;
                    Run(base, Depth + 1, False);
                  end;
                  ox := soX + adx - asb;
                  oy := soY + ady;
                  if Charstring(aname, accent) then
                  begin
                    ended := False;
                    G.Path.MoveTo(cx, cy);
                    Run(accent, Depth + 1, False);
                  end;
                  ox := soX; oy := soY;
                  ended := True;
                  Exit;
                end;
              7:
                begin
                  // sbw
                  cx := ox + Arg(0);
                  cy := oy + Arg(1);
                  if TopLevel then G.Width := Arg(2);
                  sp := 0;
                end;
              12:
                begin
                  // div
                  if sp >= 2 then
                  begin
                    if st[sp - 1] <> 0 then st[sp - 2] := st[sp - 2] / st[sp - 1];
                    Dec(sp);
                  end;
                end;
              16:
                begin
                  // callothersubr: flex (0, 1, 2), hint replacement (3)
                  oth := Trunc(Arg(sp - 1));
                  n := Trunc(Arg(sp - 2));
                  Dec(sp, Min(sp, 2));
                  n := EnsureRange(n, 0, Min(sp, 16));
                  for k := 0 to n - 1 do args[k] := st[sp - n + k];
                  Dec(sp, n);
                  case oth of
                    1:
                      begin
                        flexing := True;
                        nflex := 0;
                      end;
                    2:
                      if flexing and (nflex <= High(flex)) then
                      begin
                        flex[nflex] := XVPt(cx, cy);
                        Inc(nflex);
                      end;
                    0:
                      begin
                        flexing := False;
                        if nflex >= 7 then
                        begin
                          EnsureMove;
                          G.Path.CubicTo(flex[1].X, flex[1].Y, flex[2].X, flex[2].Y, flex[3].X, flex[3].Y);
                          G.Path.CubicTo(flex[4].X, flex[4].Y, flex[5].X, flex[5].Y, flex[6].X, flex[6].Y);
                          cx := flex[6].X;
                          cy := flex[6].Y;
                        end;
                        // "pop pop setcurrentpoint" follows: x first
                        psp := 0;
                        pss[0] := cy - oy;
                        pss[1] := cx - ox;
                        psp := 2;
                      end;
                    3:
                      begin
                        psp := 1;
                        pss[0] := 3;
                      end;
                  else
                    begin
                      psp := 0;
                      for k := n - 1 downto 0 do
                        if psp <= High(pss) then
                        begin
                          pss[psp] := args[k];
                          Inc(psp);
                        end;
                    end;
                  end;
                end;
              17:
                begin
                  // pop: a result of the last othersubr
                  if psp > 0 then
                  begin
                    Dec(psp);
                    Push(pss[psp]);
                  end
                  else Push(0);
                end;
              33:
                begin
                  // setcurrentpoint
                  cx := ox + Arg(0);
                  cy := oy + Arg(1);
                  sp := 0;
                end;
            else
              sp := 0;
            end;
          end;
      else
        sp := 0;
      end;
    end;
  end;

var
  code: TBytes;
begin
  Result := False;
  G := Default(TPSGlyph);
  G.Path.Clear;
  if not (DictGet(FD, 'CharStrings', cstr) and (cstr.K = okDict)) then Exit;
  if not (DictGet(FD, 'Private', priv) and (priv.K = okDict)) then Exit;
  lenIV := 4;
  if DictGet(priv.D, 'lenIV', o) and IsNum(o) then lenIV := Round(NumOf(o));
  if not DictGet(priv.D, 'Subrs', subrs) then subrs := NullObj;
  if not Charstring(Name, code) then Exit;
  sp := 0; psp := 0; nflex := 0;
  cx := 0; cy := 0; ox := 0; oy := 0;
  flexing := False;
  ended := False;
  for i := 0 to High(pss) do pss[i] := 0;
  Run(code, 0, True);
  G.Ok := True;
  Result := True;
end;

// ------------------------------ TrueType (Type 42) -------------------------

function BE16(const D: TBytes; P: Integer): Integer; inline;
begin
  if (P < 0) or (P + 1 >= Length(D)) then Exit(0);
  Result := (D[P] shl 8) or D[P + 1];
end;

function BE16S(const D: TBytes; P: Integer): Integer; inline;
begin
  Result := SmallInt(BE16(D, P));
end;

function BE32(const D: TBytes; P: Integer): Cardinal; inline;
begin
  if (P < 0) or (P + 3 >= Length(D)) then Exit(0);
  Result := (Cardinal(D[P]) shl 24) or (Cardinal(D[P + 1]) shl 16) or (Cardinal(D[P + 2]) shl 8) or D[P + 3];
end;

function TPSInterp.TrueTypeOf(const Sfnts: TPSObj): TPSTrueType;
var
  key: PtrUInt;
  tt: TPSTrueType;
  i, n, p, num: Integer;
  s: TPSObj;
  tag: string;
  ofs: Cardinal;
begin
  if Sfnts.K <> okArray then Exit(nil);
  key := PtrUInt(Sfnts.A) + PtrUInt(Sfnts.Off);
  if TTCache.TryGetValue(key, Result) then Exit;
  tt := TPSTrueType.Create;
  Objs.Add(tt);
  // the strings together; an odd-length string ends with a padding byte
  n := 0;
  for i := 0 to Sfnts.Len - 1 do
  begin
    s := ArrItem(Sfnts, i);
    if s.K <> okString then Continue;
    num := s.Len;
    if Odd(num) then Dec(num);
    SetLength(tt.Data, n + num);
    if num > 0 then Move(s.S.Data[s.Off], tt.Data[n], num);
    Inc(n, num);
  end;
  num := BE16(tt.Data, 4);
  for i := 0 to num - 1 do
  begin
    p := 12 + 16 * i;
    if p + 16 > Length(tt.Data) then Break;
    SetLength(tag, 4);
    Move(tt.Data[p], tag[1], 4);
    ofs := BE32(tt.Data, p + 8);
    if tag = 'head' then
    begin
      tt.UnitsPerEm := BE16(tt.Data, ofs + 18);
      tt.LongLoca := BE16S(tt.Data, ofs + 50) <> 0;
    end
    else if tag = 'loca' then tt.Loca := ofs
    else if tag = 'glyf' then tt.Glyf := ofs
    else if tag = 'hmtx' then tt.Hmtx := ofs
    else if tag = 'hhea' then tt.NumHMetrics := BE16(tt.Data, ofs + 34)
    else if tag = 'maxp' then tt.NumGlyphs := BE16(tt.Data, ofs + 4);
  end;
  if tt.UnitsPerEm <= 0 then tt.UnitsPerEm := 1000;
  tt.Ok := (tt.Loca > 0) and (tt.Glyf > 0);
  TTCache.Add(key, tt);
  Result := tt;
end;

// a glyph's quadratic contours, through M (composite glyphs nest)
procedure TrueTypeOutline(TT: TPSTrueType; Gid: Integer; const M: TXVMatrix; var Path: TXVPath; Depth: Integer);
var
  d: TBytes;
  o0, o1, p, nc, n, i, k, c, flags, rep, gi, a1, a2, startI, endI, first: Integer;
  ends: array of Integer;
  fl: array of Byte;
  xs, ys: array of Integer;
  v: Integer;
  cm: TXVMatrix;
  sa, sb, sc, sd: Double;
  pts: array of TXVPoint;
  on: array of Boolean;
  ctrl, mid, st: TXVPoint;
  cnt: Integer;
  pending: Boolean;

  function Loc(G: Integer): Integer;
  begin
    if TT.LongLoca then Result := TT.Glyf + Integer(BE32(d, TT.Loca + 4 * G))
    else Result := TT.Glyf + 2 * BE16(d, TT.Loca + 2 * G);
  end;

  function F2Dot14(P_: Integer): Double;
  begin
    Result := BE16S(d, P_) / 16384;
  end;

begin
  if (Depth > 8) or not TT.Ok then Exit;
  d := TT.Data;
  if (Gid < 0) or ((TT.NumGlyphs > 0) and (Gid >= TT.NumGlyphs)) then Exit;
  o0 := Loc(Gid);
  o1 := Loc(Gid + 1);
  if (o1 <= o0) or (o0 + 10 > Length(d)) then Exit;
  nc := BE16S(d, o0);
  p := o0 + 10;
  if nc >= 0 then
  begin
    SetLength(ends, nc);
    for i := 0 to nc - 1 do ends[i] := BE16(d, p + 2 * i);
    Inc(p, 2 * nc);
    if nc = 0 then Exit;
    n := ends[nc - 1] + 1;
    if (n <= 0) or (n > 65536) then Exit;
    Inc(p, 2 + BE16(d, p));                     // instructions
    SetLength(fl, n);
    i := 0;
    while (i < n) and (p < Length(d)) do
    begin
      flags := d[p];
      Inc(p);
      fl[i] := flags;
      Inc(i);
      if (flags and 8) <> 0 then
      begin
        if p >= Length(d) then Break;
        rep := d[p];
        Inc(p);
        while (rep > 0) and (i < n) do
        begin
          fl[i] := flags;
          Inc(i);
          Dec(rep);
        end;
      end;
    end;
    SetLength(xs, n);
    SetLength(ys, n);
    v := 0;
    for i := 0 to n - 1 do
    begin
      if (fl[i] and 2) <> 0 then
      begin
        if p < Length(d) then
          if (fl[i] and 16) <> 0 then Inc(v, d[p]) else Dec(v, d[p]);
        Inc(p);
      end
      else if (fl[i] and 16) = 0 then
      begin
        Inc(v, BE16S(d, p));
        Inc(p, 2);
      end;
      xs[i] := v;
    end;
    v := 0;
    for i := 0 to n - 1 do
    begin
      if (fl[i] and 4) <> 0 then
      begin
        if p < Length(d) then
          if (fl[i] and 32) <> 0 then Inc(v, d[p]) else Dec(v, d[p]);
        Inc(p);
      end
      else if (fl[i] and 32) = 0 then
      begin
        Inc(v, BE16S(d, p));
        Inc(p, 2);
      end;
      ys[i] := v;
    end;
    // contours: on-curve points and quadratic controls (midpoints implied)
    startI := 0;
    for c := 0 to nc - 1 do
    begin
      endI := Min(ends[c], n - 1);
      cnt := endI - startI + 1;
      if cnt < 2 then
      begin
        startI := endI + 1;
        Continue;
      end;
      SetLength(pts, cnt);
      SetLength(on, cnt);
      for k := 0 to cnt - 1 do
      begin
        pts[k] := M.Apply(xs[startI + k], ys[startI + k]);
        on[k] := (fl[startI + k] and 1) <> 0;
      end;
      first := -1;
      for k := 0 to cnt - 1 do
        if on[k] then begin first := k; Break; end;
      if first < 0 then
        st := XVPt((pts[0].X + pts[1].X) / 2, (pts[0].Y + pts[1].Y) / 2)
      else st := pts[first];
      if first < 0 then first := 0;
      Path.MoveTo(st.X, st.Y);
      pending := False;
      for k := 1 to cnt do
      begin
        i := (first + k) mod cnt;
        if on[i] then
        begin
          if pending then Path.QuadTo(ctrl.X, ctrl.Y, pts[i].X, pts[i].Y)
          else Path.LineTo(pts[i].X, pts[i].Y);
          pending := False;
        end
        else
        begin
          if pending then
          begin
            mid := XVPt((ctrl.X + pts[i].X) / 2, (ctrl.Y + pts[i].Y) / 2);
            Path.QuadTo(ctrl.X, ctrl.Y, mid.X, mid.Y);
          end;
          ctrl := pts[i];
          pending := True;
        end;
      end;
      if pending then Path.QuadTo(ctrl.X, ctrl.Y, st.X, st.Y);
      Path.Close;
      startI := endI + 1;
    end;
  end
  else
  begin
    // composite glyph
    repeat
      if p + 4 > Length(d) then Exit;
      flags := BE16(d, p);
      gi := BE16(d, p + 2);
      Inc(p, 4);
      if (flags and 1) <> 0 then
      begin
        a1 := BE16S(d, p);
        a2 := BE16S(d, p + 2);
        Inc(p, 4);
      end
      else
      begin
        a1 := ShortInt(d[p]);
        a2 := ShortInt(d[p + 1]);
        Inc(p, 2);
      end;
      if (flags and 2) = 0 then begin a1 := 0; a2 := 0; end;    // point matching: not done
      sa := 1; sb := 0; sc := 0; sd := 1;
      if (flags and 8) <> 0 then
      begin
        sa := F2Dot14(p); sd := sa;
        Inc(p, 2);
      end
      else if (flags and $40) <> 0 then
      begin
        sa := F2Dot14(p); sd := F2Dot14(p + 2);
        Inc(p, 4);
      end
      else if (flags and $80) <> 0 then
      begin
        sa := F2Dot14(p); sb := F2Dot14(p + 2); sc := F2Dot14(p + 4); sd := F2Dot14(p + 6);
        Inc(p, 8);
      end;
      cm := XVMul(M, TXVMatrix.Make(sa, sb, sc, sd, a1, a2));
      TrueTypeOutline(TT, gi, cm, Path, Depth + 1);
    until (flags and $20) = 0;
  end;
end;

function TPSInterp.Type42Glyph(FD: TPSDict; const Name: string; out G: TPSGlyph): Boolean;
var
  cs, sf, gidObj: TPSObj;
  tt: TPSTrueType;
  gid, nh: Integer;
begin
  Result := False;
  G := Default(TPSGlyph);
  G.Path.Clear;
  if not (DictGet(FD, 'sfnts', sf) and DictGet(FD, 'CharStrings', cs) and (cs.K = okDict)) then Exit;
  if not DictGet(cs.D, Name, gidObj) then
    if not DictGet(cs.D, '.notdef', gidObj) then Exit;
  if not IsNum(gidObj) then Exit;
  gid := Round(NumOf(gidObj));
  tt := TrueTypeOf(sf);
  if (tt = nil) or not tt.Ok then Exit;
  // em units: Type 42 glyph space has the em at 1
  TrueTypeOutline(tt, gid, TXVMatrix.Scale(1 / tt.UnitsPerEm, 1 / tt.UnitsPerEm), G.Path, 0);
  nh := tt.NumHMetrics;
  if nh > 0 then
  begin
    if gid >= nh then gid := nh - 1;
    G.Width := BE16(tt.Data, tt.Hmtx + 4 * gid) / tt.UnitsPerEm;
  end;
  G.Ok := True;
  Result := True;
end;

// 1: Type 1 outlines, 42: TrueType outlines, 0: none (a system font draws it)
function TPSInterp.OutlineKind(const F: TPSObj): Integer;
var o: TPSObj; ft: Integer;
begin
  Result := 0;
  if F.K <> okDict then Exit;
  ft := 1;
  if DictGet(F.D, 'FontType', o) and IsNum(o) then ft := Round(NumOf(o));
  if (ft = 1) and DictGet(F.D, 'CharStrings', o) and (o.K = okDict) and DictGet(F.D, 'Private', o) and
    (o.K = okDict) then Result := 1
  else if (ft = 42) and DictGet(F.D, 'sfnts', o) and (o.K = okArray) and DictGet(F.D, 'CharStrings', o) then
    Result := 42;
end;

// the outline and width (glyph space) of a character code
function TPSInterp.GlyphFor(const F: TPSObj; Code: Integer; out G: TPSGlyph): Boolean;
var
  enc: TPSObj;
  name: string;
begin
  Result := False;
  G := Default(TPSGlyph);
  if F.K <> okDict then Exit;
  if not (DictGet(F.D, 'Encoding', enc) and (enc.K = okArray)) then enc := StdEnc;
  if (Code < 0) or (Code >= enc.Len) then Exit;
  name := StrOf(ArrItem(enc, Code));
  if name = '' then name := '.notdef';
  Result := GlyphByName(F, name, G);
end;

function TPSInterp.GlyphByName(const F: TPSObj; const Name: string; out G: TPSGlyph): Boolean;
var
  cs: TPSObj;
  key: string;
  kind: Integer;
begin
  Result := False;
  G := Default(TPSGlyph);
  kind := OutlineKind(F);
  if kind = 0 then Exit;
  DictGet(F.D, 'CharStrings', cs);
  key := IntToHex(PtrUInt(cs.D), 16) + '/' + Name;
  if GlyphCache.TryGetValue(key, G) then Exit(G.Ok);
  if kind = 1 then Result := Type1Glyph(F.D, Name, G)
  else Result := Type42Glyph(F.D, Name, G);
  G.Path.Compact;
  GlyphCache.AddOrSetValue(key, G);
end;

// show with the font's own outlines: Mode as ShowText's
procedure TPSInterp.ShowOutlines(const S: TPSObj; Mode: Integer; AX, AY, CX, CY: Double; CChar: Integer;
  const Disp: TPSObj);
var
  fm, gm: TXVMatrix;
  fam: string;
  bold, ital: Boolean;
  x, y: Double;
  i, code: Integer;
  g: TPSGlyph;
  all, gp, savePath: TXVPath;
  p: TXVPoint;
  font: TXVFont;
begin
  FontInfo(GS.Font, fam, bold, ital, fm);
  CurPointUser(x, y);
  all := Default(TXVPath);
  all.Clear;
  font := XVDefaultFont;
  font.Family := fam;
  font.Size := 1000;
  for i := 0 to S.Len - 1 do
  begin
    code := S.S.Data[S.Off + i];
    if GlyphFor(GS.Font, code, g) then
    begin
      if g.Path.NCmd > 0 then
      begin
        gm := XVMul(GS.CTM, XVMul(TXVMatrix.Translate(x, y), fm));
        gp := g.Path.Copy;
        gp.Transform(gm);
        all.Append(gp);
      end;
      p := fm.ApplyVec(g.Width, 0);
    end
    else
      // a glyph the font lacks: the width of a system font's
      p := fm.ApplyVec(XVEstimateTextWidth(font, XVUtf8OfCode(GlyphUnicode(GS.Font, code))), 0);
    if (Mode in [5, 7]) and (Disp.K = okArray) then
    begin
      // explicit displacements replace the widths
      if Mode = 5 then
      begin
        if i < Disp.Len then p := XVPt(NumOf(ArrItem(Disp, i)), 0) else p := XVPt(0, 0);
      end
      else if 2 * i + 1 < Disp.Len then p := XVPt(NumOf(ArrItem(Disp, 2 * i)), NumOf(ArrItem(Disp, 2 * i + 1)))
      else p := XVPt(0, 0);
    end;
    x := x + p.X;
    y := y + p.Y;
    if Mode in [1, 3] then begin x := x + AX; y := y + AY; end;
    if (Mode in [2, 3]) and (code = CChar) then begin x := x + CX; y := y + CY; end;
  end;
  if Mode = 9 then GS.Path.Append(all)
  else if all.NCmd > 0 then
  begin
    savePath := GS.Path;
    GS.Path := all;
    Emit(True, frNonZero);
    GS.Path := savePath;
  end;
  p := UserToDev(x, y);
  GS.Path.MoveTo(p.X, p.Y);
  if bold or ital then ;
end;
