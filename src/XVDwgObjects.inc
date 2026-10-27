// XelVectors - DWG objects: tables and entities, and their assembly into
// the CAD model. Included by XVReadDWG.pas.

const
  LINE_WEIGHTS: array[0..31] of Integer = (0, 5, 9, 13, 15, 18, 20, 25, 30, 35, 40, 50, 53, 60, 70, 80, 90, 100,
    106, 120, 140, 158, 200, 211, 0, 0, 0, 0, 0, -1, -2, -3);

  // DWG types
  T_TEXT = 1; T_ATTRIB = 2; T_ATTDEF = 3; T_INSERT = 7; T_MINSERT = 8; T_VERTEX2D = 10; T_VERTEX3D = 11;
  T_VERTEXMESH = 12; T_VERTEXPFACE = 13; T_POLYLINE2D = 15; T_POLYLINE3D = 16; T_ARC = 17; T_CIRCLE = 18;
  T_LINE = 19; T_POINT = 27; T_3DFACE = 28; T_SOLID = 31; T_TRACE = 32; T_ELLIPSE = 35; T_SPLINE = 36;
  T_MTEXT = 44; T_LEADER = 45; T_BLOCKHEADER = 49; T_LAYER = 51; T_STYLE = 53; T_LTYPE = 57;
  T_LWPOLYLINE = 77; T_HATCH = 78;
  // variable types
  T_IMAGEDEF = 1002; T_IMAGE = 1003; T_WIPEOUT = 1004;

function IsEntityType(T: Integer): Boolean;
begin
  Result := (T in [1..41]) or (T in [43..47]) or (T = 74) or (T = 77) or (T = 78) or (T = 498);
end;

function RadToDeg_(A: Double): Double; inline;
begin
  Result := A * 180 / Pi;
end;

procedure TDwgReader.ReadObject(const Ent: TDwgMapEntry);
var
  m, s, h: TBits;
  size, hsize, bitsize, savePos, objH, psz: Int64;
  typ, code, n, i, k: Integer;
  c: TDwgClass;
  isEnt: Boolean;
  // entity common data
  entMode, numReact, ltFlags, plotFlags, matFlags: Integer;
  xdicMissing, noLinks, byLayerLt, hasBook, fullVs, faceVs, edgeVs: Boolean;
  E: TCadEntity;
  de: TDwgEnt;
  owner, layerH, ltypeH: Int64;
  // scratch
  p, q: TCadVec;
  d1, d2: Double;
  fl, nb, nw, nid, nf: Integer;
  L: TCadLoop;
  ed: TCadEdge;
  pl: TCadPatLine;
  derived, bulges: Boolean;
  name: string;
  lay: TCadLayer;
  lt: TCadLType;
  st: TCadStyle;
  br: TDwgBlockRec;
  cv: Integer;
  w: Integer;
  rgb: Cardinal;
  gc: Integer;

  function T: string;
  begin
    if Ver >= R2007 then Result := s.ReadTU else Result := m.ReadTV;
  end;

  function DD3(const Def: TCadVec): TCadVec;
  begin
    Result.X := m.ReadDD(Def.X);
    Result.Y := m.ReadDD(Def.Y);
    Result.Z := m.ReadDD(Def.Z);
  end;

  // CMC: a colour as ACI (or $1000000 or RGB for a true colour)
  function ReadCMC: Integer;
  var idx: Integer; r: Cardinal; f: Byte;
  begin
    idx := m.ReadBS;
    Result := idx;
    if Ver >= R2004 then
    begin
      r := Cardinal(m.ReadBL);
      f := m.ReadRC;
      if (f and 1) <> 0 then T;
      if (f and 2) <> 0 then T;
      case r shr 24 of
        $C0: Result := 256;
        $C1: Result := 0;
        $C2: Result := $1000000 or Integer(r and $FFFFFF);
        $C3: Result := r and $FF;
      end;
    end;
  end;

  procedure ObjCommon;
  begin
    numReact := m.ReadBL;
    xdicMissing := False;
    if Ver >= R2004 then xdicMissing := m.ReadB = 1;
    if Ver >= R2013 then m.ReadB;
  end;

  procedure ObjHandles;
  var j: Integer;
  begin
    owner := h.ReadHRef(objH);
    for j := 1 to Min(numReact, 10000) do h.ReadHRef(objH);
    if not xdicMissing then h.ReadHRef(objH);
  end;

  procedure TableName;
  begin
    name := T;
    m.ReadB;
    m.ReadBS;
    m.ReadB;
  end;

  procedure EntCommon;
  var idx: Integer;
  begin
    entMode := m.ReadBB;
    numReact := m.ReadBL;
    xdicMissing := False;
    if Ver >= R2004 then xdicMissing := m.ReadB = 1;
    if Ver >= R2013 then m.ReadB;
    byLayerLt := True;
    if Ver <= R14 then byLayerLt := m.ReadB = 1;
    noLinks := True;
    if Ver <= R2000 then noLinks := m.ReadB = 1;
    hasBook := False;
    if Ver >= R2004 then
    begin
      idx := m.ReadBS;
      w := idx and $FFFF;
      E.Color := w and $1FF;
      if w <> 0 then
      begin
        if (w and $8000) <> 0 then
        begin
          rgb := Cardinal(m.ReadBL);
          case rgb shr 24 of
            $C0: E.Color := 256;
            $C1: E.Color := 0;
            $C2: E.TrueColor := rgb and $FFFFFF;
            $C3: E.Color := rgb and $FF;
          end;
        end;
        if (w and $4000) <> 0 then hasBook := True;
        if (w and $2000) <> 0 then
        begin
          rgb := Cardinal(m.ReadBL);
          if (rgb shr 24) = 3 then E.Transparency := 1 - (rgb and $FF) / 255;
        end;
      end;
    end
    else E.Color := m.ReadBS;
    E.LTScale := m.ReadBD;
    ltFlags := 0;
    plotFlags := 0;
    matFlags := 0;
    if Ver >= R2000 then
    begin
      ltFlags := m.ReadBB;
      plotFlags := m.ReadBB;
    end;
    if Ver >= R2007 then
    begin
      matFlags := m.ReadBB;
      m.ReadRC;
    end;
    fullVs := False; faceVs := False; edgeVs := False;
    if Ver >= R2010 then
    begin
      fullVs := m.ReadB = 1;
      faceVs := m.ReadB = 1;
      edgeVs := m.ReadB = 1;
    end;
    E.Invisible := (m.ReadBS and 1) <> 0;
    if Ver >= R2000 then E.LWeight := LINE_WEIGHTS[m.ReadRC and 31];
    E.PaperSpace := entMode = 1;
  end;

  procedure EntHandles;
  var j: Integer;
  begin
    owner := 0;
    ltypeH := 0;
    layerH := 0;
    if entMode = 0 then owner := h.ReadHRef(objH);
    for j := 1 to Min(numReact, 10000) do h.ReadHRef(objH);
    if not xdicMissing then h.ReadHRef(objH);
    if Ver <= R14 then
    begin
      layerH := h.ReadHRef(objH);
      if not byLayerLt then
      begin
        ltypeH := h.ReadHRef(objH);
        ltFlags := 3;
      end;
    end;
    if (Ver <= R2000) and not noLinks then
    begin
      h.ReadHRef(objH);
      h.ReadHRef(objH);
    end;
    if (Ver >= R2004) and hasBook then h.ReadHRef(objH);
    if Ver >= R2000 then
    begin
      layerH := h.ReadHRef(objH);
      if ltFlags = 3 then ltypeH := h.ReadHRef(objH);
    end;
    if (Ver >= R2007) and (matFlags = 3) then h.ReadHRef(objH);
    if (Ver >= R2000) and (plotFlags = 3) then h.ReadHRef(objH);
    if Ver >= R2010 then
    begin
      if fullVs then h.ReadHRef(objH);
      if faceVs then h.ReadHRef(objH);
      if edgeVs then h.ReadHRef(objH);
    end;
  end;

  procedure AddPt(var A: TCadVecs; const V: TCadVec);
  begin
    SetLength(A, Length(A) + 1);
    A[High(A)] := V;
  end;

  procedure AddD(var A: TXVDoubles; V: Double);
  begin
    SetLength(A, Length(A) + 1);
    A[High(A)] := V;
  end;

  procedure Keep;
  begin
    if Debug and (m.Bad or h.Bad or ((Ver >= R2007) and s.Bad) or (m.Pos > bitsize)) then
      Log(Format('object %x type %d: overrun main %d/%d bad %d %d %d', [objH, typ, m.Pos, bitsize, Ord(m.Bad), Ord(h.Bad), Ord(s.Bad)]));
    de.Ent := E;
    de.Typ := typ;
    de.Handle := objH;
    de.Owner := owner;
    de.EntMode := entMode;
    de.LayerH := layerH;
    de.LTypeH := ltypeH;
    de.LTFlags := ltFlags;
    if NEnts >= Length(Ents) then SetLength(Ents, Max(256, NEnts * 2));
    Ents[NEnts] := de;
    Inc(NEnts);
  end;

  // a wipeout's boundary (in its pixel space) as world points
  procedure WipeoutPts;
  var
    k: Integer;
    c: TCadVecs;
    ww, hh, x, y: Double;
    ins: TCadVec;
  begin
    E.Kind := ceWipeout;
    ww := Max(E.ImageSize.X, 1e-9);
    hh := Max(E.ImageSize.Y, 1e-9);
    c := E.ClipPts;
    if not E.ClipOn or (Length(c) < 2) then
    begin
      SetLength(c, 2);
      c[0] := CadVec(-0.5, -0.5);
      c[1] := CadVec(ww - 0.5, hh - 0.5);
    end;
    if Length(c) = 2 then
    begin
      SetLength(c, 4);
      c[2] := c[1];
      c[1] := CadVec(c[2].X, c[0].Y);
      c[3] := CadVec(c[0].X, c[2].Y);
    end;
    ins := E.Pts[0];
    SetLength(E.Pts, Length(c));
    for k := 0 to High(c) do
    begin
      x := c[k].X + 0.5;
      y := hh - 0.5 - c[k].Y;
      E.Pts[k] := CadVec(ins.X + x * E.UVec.X + y * E.VVec.X, ins.Y + x * E.UVec.Y + y * E.VVec.Y);
    end;
    E.ClipPts := nil;
  end;

  procedure ReadText;
  var df, gen: Integer;
  begin
    E.Kind := ceText;
    SetLength(E.Pts, 1);
    gen := 0;
    if Ver <= R14 then
    begin
      E.Elevation := m.ReadBD;
      p := m.Read2RD;
      q := m.Read2RD;
      E.Extrusion := m.Read3BD;
      m.ReadBD;
      E.Oblique := RadToDeg_(m.ReadBD);
      E.Rotation := RadToDeg_(m.ReadBD);
      E.Height := m.ReadBD;
      E.WidthFactor := m.ReadBD;
      E.Text := T;
      gen := m.ReadBS;
      E.HAlign := m.ReadBS;
      E.VAlign := m.ReadBS;
      E.HasAlignPt := (E.HAlign <> 0) or (E.VAlign <> 0);
    end
    else
    begin
      df := m.ReadRC;
      if (df and 1) = 0 then E.Elevation := m.ReadRD;
      p := m.Read2RD;
      q := p;
      if (df and 2) = 0 then
      begin
        q.X := m.ReadDD(p.X);
        q.Y := m.ReadDD(p.Y);
        E.HasAlignPt := True;
      end;
      E.Extrusion := m.ReadBE;
      m.ReadBT;
      if (df and 4) = 0 then E.Oblique := RadToDeg_(m.ReadRD);
      if (df and 8) = 0 then E.Rotation := RadToDeg_(m.ReadRD);
      E.Height := m.ReadRD;
      if (df and 16) = 0 then E.WidthFactor := m.ReadRD;
      E.Text := T;
      if (df and 32) = 0 then gen := m.ReadBS;
      if (df and 64) = 0 then E.HAlign := m.ReadBS;
      if (df and 128) = 0 then E.VAlign := m.ReadBS;
    end;
    E.Pts[0] := p;
    E.AlignPt := q;
    E.Backwards := (gen and 2) <> 0;
    E.UpsideDown := (gen and 4) <> 0;
  end;

begin
  if (Ent.Offset < 0) or (Ent.Offset + 2 >= Length(ObjBuf)) then Exit;
  m.Init(ObjBuf, Ent.Offset, Min(Length(ObjBuf) - Ent.Offset, 16), Ver);
  size := m.ReadMS;
  savePos := Ent.Offset + (m.Pos shr 3);
  if (size <= 0) or (savePos + size > Length(ObjBuf)) then Exit;
  hsize := 0;
  if Ver >= R2010 then
  begin
    // the handle stream size; the object's data starts after it
    m.Init(ObjBuf, savePos, Min(Length(ObjBuf) - savePos, 16), Ver);
    hsize := m.ReadUMC;
    savePos := savePos + (m.Pos shr 3);
    if savePos + size > Length(ObjBuf) then Exit;
  end;
  m.Init(ObjBuf, savePos, size, Ver);
  m.CodePage := CodePage;
  if Ver >= R2010 then typ := m.ReadOT else typ := m.ReadBS;
  bitsize := 0;
  if (Ver >= R2000) and (Ver <= R2007) then bitsize := m.ReadRL;
  if Ver >= R2010 then bitsize := size * 8 - hsize;
  objH := m.ReadH(code);
  // extended entity data
  repeat
    n := m.ReadBS;
    if n <= 0 then Break;
    m.ReadH(code);
    m.Skip(Int64(n) * 8);
  until m.Bad;
  if typ >= 500 then
  begin
    if not ClassOf(typ, c) then Exit;
    isEnt := c.IsEntity;
    if c.DxfName = 'LWPOLYLINE' then typ := T_LWPOLYLINE
    else if c.DxfName = 'HATCH' then typ := T_HATCH
    else if c.DxfName = 'IMAGE' then typ := T_IMAGE
    else if c.DxfName = 'WIPEOUT' then typ := T_WIPEOUT
    else if c.DxfName = 'IMAGEDEF' then typ := T_IMAGEDEF
    else if not isEnt then Exit
    else typ := 1000;
  end
  else isEnt := IsEntityType(typ);
  if isEnt then
  begin
    if m.ReadB = 1 then
    begin
      if Ver >= R2010 then psz := m.ReadBLL else psz := m.ReadRL;
      m.Skip(psz * 8);
    end;
  end;
  if Ver <= R14 then bitsize := m.ReadRL;
  if (bitsize <= 0) or (bitsize > size * 8) then bitsize := size * 8;
  if Ver >= R2007 then
  begin
    savePos := m.Pos;
    StringStream(m, bitsize, s);
    m.Pos := savePos;
  end;
  h := m;
  h.Pos := bitsize;
  owner := 0; layerH := 0; ltypeH := 0; entMode := 0; ltFlags := 0;
  de := Default(TDwgEnt);

  if not isEnt then
  begin
    ObjCommon;
    case typ of
      T_BLOCKHEADER:
        begin
          TableName;
          m.ReadB; m.ReadB; m.ReadB; m.ReadB;    // anonymous, has attributes, xref, overlaid
          if Ver >= R2000 then m.ReadB;           // loaded
          if Ver >= R2004 then m.ReadBL;          // owned objects
          br.Name := name;
          // anonymous blocks (*D, *U, *T ...) share their names: made unique
          if (name <> '') and (name[1] = '*') and not SameText(name, '*Model_Space') and
            not SameText(Copy(name, 1, 12), '*Paper_Space') then br.Name := name + '~' + IntToHex(objH, 1);
          br.Base := m.Read3BD;
          if m.Bad then br.Base := CadVec(0, 0);
          BlockRecs.AddOrSetValue(objH, br);
          Log(Format('block %x %s', [objH, name]));
        end;
      T_LAYER:
        begin
          TableName;
          lay := Default(TCadLayer);
          lay.Name := name;
          lay.TrueColor := -1;
          lay.LType := 'CONTINUOUS';
          lay.LWeight := -3;
          if Ver <= R14 then
          begin
            lay.Frozen := m.ReadB = 1;
            m.ReadB;                               // "on": off layers have a negative colour
            m.ReadB; m.ReadB;
          end
          else
          begin
            fl := m.ReadBS;
            lay.Frozen := (fl and 1) <> 0;
            lay.Off := (fl and 2) <> 0;
            lay.LWeight := LINE_WEIGHTS[(fl shr 5) and 31];
          end;
          cv := ReadCMC;
          if cv < 0 then
          begin
            lay.Off := True;
            cv := -cv;
          end;
          if cv >= $1000000 then
          begin
            lay.TrueColor := cv and $FFFFFF;
            lay.Color := 7;
          end
          else lay.Color := cv;
          ObjHandles;
          h.ReadHRef(objH);                      // xref block
          if Ver >= R2000 then h.ReadHRef(objH);  // plot style
          if Ver >= R2007 then h.ReadHRef(objH);  // material
          LayerLTypeH.AddOrSetValue(objH, h.ReadHRef(objH));
          LayerIdx.AddOrSetValue(objH, Cad.AddLayer(lay));
          Log(Format('layer %x %s color %d off %d flags %d', [objH, name, lay.Color, Ord(lay.Off), fl]));
        end;
      T_LTYPE:
        begin
          TableName;
          lt := Default(TCadLType);
          lt.Name := name;
          T;                                       // description
          m.ReadBD;                                // pattern length
          m.ReadRC;                                // alignment
          n := m.ReadRC;
          for i := 0 to n - 1 do
          begin
            d1 := m.ReadBD;
            m.ReadBS; m.ReadRD; m.ReadRD; m.ReadBD; m.ReadBD; m.ReadBS;
            if m.Bad then Break;
            SetLength(lt.Dashes, Length(lt.Dashes) + 1);
            lt.Dashes[High(lt.Dashes)] := d1;
          end;
          SetLength(Cad.LTypes, Length(Cad.LTypes) + 1);
          Cad.LTypes[High(Cad.LTypes)] := lt;
          LTypeNames.AddOrSetValue(objH, name);
        end;
      T_IMAGEDEF:
        begin
          m.ReadBL;                                // class version
          m.Read2RD;                               // size in pixels
          ImageDefs.AddOrSetValue(objH, T);
        end;
      T_STYLE:
        begin
          TableName;
          st := Default(TCadStyle);
          st.Name := name;
          m.ReadB; m.ReadB;
          st.Height := m.ReadBD;
          st.WidthFactor := m.ReadBD;
          st.Oblique := RadToDeg_(m.ReadBD);
          m.ReadRC;
          m.ReadBD;
          st.Font := T;
          st.BigFont := T;
          if st.WidthFactor <= 0 then st.WidthFactor := 1;
          SetLength(Cad.Styles, Length(Cad.Styles) + 1);
          Cad.Styles[High(Cad.Styles)] := st;
          StyleNames.AddOrSetValue(objH, name);
        end;
    end;
    Exit;
  end;

  // entities
  E := XVNewCadEntity(ceNone);
  EntCommon;
  case typ of
    T_TEXT, T_ATTRIB:
      begin
        ReadText;
        if (typ = T_ATTRIB) and (Ver < R2018) then
        begin
          if Ver >= R2010 then m.ReadRC;
          T;                                       // tag
          m.ReadBS;
          if (m.ReadRC and 1) <> 0 then E.Invisible := True;
        end;
        EntHandles;
        de.StyleH := h.ReadHRef(objH);
        Keep;
      end;
    T_INSERT, T_MINSERT:
      begin
        E.Kind := ceInsert;
        SetLength(E.Pts, 1);
        E.Pts[0] := m.Read3BD;
        if Ver >= R2000 then
        begin
          case m.ReadBB of
            3: E.Scale := CadVec(1, 1, 1);
            1: begin E.Scale.X := 1; E.Scale.Y := m.ReadDD(1); E.Scale.Z := m.ReadDD(1); end;
            2: begin E.Scale.X := m.ReadRD; E.Scale.Y := E.Scale.X; E.Scale.Z := E.Scale.X; end;
          else
            begin
              E.Scale.X := m.ReadRD;
              E.Scale.Y := m.ReadDD(E.Scale.X);
              E.Scale.Z := m.ReadDD(E.Scale.X);
            end;
          end;
        end
        else E.Scale := m.Read3BD;
        E.Rotation := RadToDeg_(m.ReadBD);
        E.Extrusion := m.Read3BD;
        if (m.ReadB = 1) and (Ver >= R2004) then m.ReadBL;
        if typ = T_MINSERT then
        begin
          E.ColCount := Max(1, m.ReadBS);
          E.RowCount := Max(1, m.ReadBS);
          E.ColSpacing := m.ReadBD;
          E.RowSpacing := m.ReadBD;
        end;
        EntHandles;
        de.BlockH := h.ReadHRef(objH);
        Keep;
      end;
    T_VERTEX2D:
      begin
        de.Flags := m.ReadRC;
        SetLength(E.Pts, 1);
        E.Pts[0] := m.Read3BD;
        d1 := m.ReadBD;
        if d1 < 0 then begin d1 := -d1; d2 := d1; end
        else d2 := m.ReadBD;
        AddD(E.SWidths, d1);
        AddD(E.EWidths, d2);
        AddD(E.Bulges, m.ReadBD);
        EntHandles;
        Keep;
      end;
    T_VERTEX3D, T_VERTEXMESH, T_VERTEXPFACE:
      begin
        de.Flags := m.ReadRC;
        SetLength(E.Pts, 1);
        E.Pts[0] := m.Read3BD;
        AddD(E.Bulges, 0);
        AddD(E.SWidths, 0);
        AddD(E.EWidths, 0);
        EntHandles;
        Keep;
      end;
    T_POLYLINE2D:
      begin
        E.Kind := cePolyline;
        fl := m.ReadBS;
        m.ReadBS;
        d1 := m.ReadBD;
        d2 := m.ReadBD;
        m.ReadBT;
        E.Elevation := m.ReadBD;
        E.Extrusion := m.ReadBE;
        E.Closed := (fl and 1) <> 0;
        if (d1 > 0) and (Abs(d1 - d2) < 1e-9) then E.ConstWidth := d1;
        de.Flags := fl;
        EntHandles;
        Keep;
      end;
    T_POLYLINE3D:
      begin
        E.Kind := cePolyline;
        m.ReadRC;
        fl := m.ReadRC;
        E.Closed := (fl and 1) <> 0;
        E.Is3D := True;
        EntHandles;
        Keep;
      end;
    T_ARC, T_CIRCLE:
      begin
        if typ = T_ARC then E.Kind := ceArc else E.Kind := ceCircle;
        p := m.Read3BD;
        E.Center := CadVec(p.X, p.Y);
        E.Elevation := p.Z;
        E.Radius := m.ReadBD;
        m.ReadBT;
        E.Extrusion := m.ReadBE;
        if typ = T_ARC then
        begin
          E.StartAngle := RadToDeg_(m.ReadBD);
          E.EndAngle := RadToDeg_(m.ReadBD);
        end;
        EntHandles;
        Keep;
      end;
    T_LINE:
      begin
        E.Kind := ceLine;
        SetLength(E.Pts, 2);
        if Ver >= R2000 then
        begin
          k := m.ReadB;
          E.Pts[0].X := m.ReadRD;
          E.Pts[1].X := m.ReadDD(E.Pts[0].X);
          E.Pts[0].Y := m.ReadRD;
          E.Pts[1].Y := m.ReadDD(E.Pts[0].Y);
          if k = 0 then
          begin
            E.Pts[0].Z := m.ReadRD;
            E.Pts[1].Z := m.ReadDD(E.Pts[0].Z);
          end;
          m.ReadBT;
          E.Extrusion := m.ReadBE;
        end
        else
        begin
          E.Pts[0] := m.Read3BD;
          E.Pts[1] := m.Read3BD;
          m.ReadBD;
          E.Extrusion := m.Read3BD;
        end;
        EntHandles;
        Keep;
      end;
    20..26:
      begin
        // dimensions are drawn by their block
        E.Kind := ceDimension;
        EntHandles;
        h.ReadHRef(objH);                           // dimension style
        de.BlockH := h.ReadHRef(objH);
        Keep;
      end;
    T_3DFACE, T_SOLID, T_TRACE:
      begin
        SetLength(E.Pts, 4);
        if typ = T_3DFACE then
        begin
          E.Kind := ceFace;
          if Ver >= R2000 then
          begin
            k := m.ReadB;                           // no flags
            i := m.ReadB;                           // z is zero
            E.Pts[0].X := m.ReadRD;
            E.Pts[0].Y := m.ReadRD;
            if i = 0 then E.Pts[0].Z := m.ReadRD;
            E.Pts[1] := DD3(E.Pts[0]);
            E.Pts[2] := DD3(E.Pts[1]);
            E.Pts[3] := DD3(E.Pts[2]);
            if k = 0 then m.ReadBS;
          end
          else
          begin
            for i := 0 to 3 do E.Pts[i] := m.Read3BD;
            m.ReadBS;
          end;
        end
        else
        begin
          E.Kind := ceSolid;
          m.ReadBT;
          E.Elevation := m.ReadBD;
          for i := 0 to 3 do E.Pts[i] := m.Read2RD;
          E.Extrusion := m.ReadBE;
        end;
        EntHandles;
        Keep;
      end;
    T_ELLIPSE:
      begin
        E.Kind := ceEllipse;
        E.Center := m.Read3BD;
        E.MajorAxis := m.Read3BD;
        E.Extrusion := m.Read3BD;
        E.Ratio := m.ReadBD;
        E.StartParam := m.ReadBD;
        E.EndParam := m.ReadBD;
        EntHandles;
        Keep;
      end;
    T_SPLINE:
      begin
        E.Kind := ceSpline;
        k := m.ReadBL;                              // scenario
        if Ver >= R2013 then
        begin
          fl := m.ReadBL;
          i := m.ReadBL;                            // knot parameterization
          if (fl and 1) <> 0 then k := 2;
          if i = 15 then k := 1;
        end;
        E.Degree := m.ReadBL;
        nf := 0;
        if (k and 1) <> 0 then
        begin
          d1 := m.ReadB;                            // rational
          E.Closed := m.ReadB = 1;
          if m.ReadB = 1 then E.Closed := True;     // periodic
          m.ReadBD; m.ReadBD;
          nb := m.ReadBL;                           // knots
          n := m.ReadBL;                            // control points
          bulges := m.ReadB = 1;                    // weighted
          if (nb > 1000000) or (n > 1000000) then Exit;
          for i := 0 to nb - 1 do AddD(E.Knots, m.ReadBD);
          for i := 0 to n - 1 do
          begin
            AddPt(E.Pts, m.Read3BD);
            if bulges then AddD(E.Weights, m.ReadBD);
          end;
        end
        else
        begin
          m.ReadBD;
          m.Read3BD;
          m.Read3BD;
          nf := m.ReadBL;
          if nf > 1000000 then Exit;
          for i := 0 to nf - 1 do AddPt(E.FitPts, m.Read3BD);
        end;
        EntHandles;
        Keep;
      end;
    T_MTEXT:
      begin
        E.Kind := ceMText;
        SetLength(E.Pts, 1);
        E.Pts[0] := m.Read3BD;
        E.Extrusion := m.Read3BD;
        E.Direction := m.Read3BD;
        E.HasDirection := True;
        E.RefWidth := m.ReadBD;
        if Ver >= R2007 then m.ReadBD;
        E.Height := m.ReadBD;
        E.Attachment := m.ReadBS;
        m.ReadBS;
        m.ReadBD;
        m.ReadBD;
        E.Text := T;
        if Ver >= R2000 then
        begin
          m.ReadBS;
          E.LineSpacing := m.ReadBD;
          if E.LineSpacing <= 0 then E.LineSpacing := 1;
          m.ReadB;
        end;
        EntHandles;
        de.StyleH := h.ReadHRef(objH);
        Keep;
      end;
    T_LEADER:
      begin
        E.Kind := ceLeader;
        m.ReadB;
        m.ReadBS;
        m.ReadBS;
        n := m.ReadBL;
        if (n < 0) or (n > 100000) then Exit;
        for i := 0 to n - 1 do AddPt(E.Pts, m.Read3BD);
        EntHandles;
        Keep;
      end;
    T_LWPOLYLINE:
      begin
        E.Kind := cePolyline;
        fl := m.ReadBS;
        if (fl and 4) <> 0 then E.ConstWidth := m.ReadBD;
        if (fl and 8) <> 0 then E.Elevation := m.ReadBD;
        if (fl and 2) <> 0 then m.ReadBD;
        if (fl and 1) <> 0 then E.Extrusion := m.Read3BD;
        n := m.ReadBL;
        nb := 0; nw := 0; nid := 0;
        if (fl and 16) <> 0 then nb := m.ReadBL;
        if (Ver >= R2010) and ((fl and 1024) <> 0) then nid := m.ReadBL;
        if (fl and 32) <> 0 then nw := m.ReadBL;
        if (n < 0) or (n > 10000000) or (nb > n + 1) or (nw > n + 1) then Exit;
        E.Closed := (fl and 512) <> 0;
        SetLength(E.Pts, n);
        SetLength(E.Bulges, n);
        for i := 0 to n - 1 do
        begin
          if (Ver <= R14) or (i = 0) then E.Pts[i] := m.Read2RD
          else
          begin
            E.Pts[i].X := m.ReadDD(E.Pts[i - 1].X);
            E.Pts[i].Y := m.ReadDD(E.Pts[i - 1].Y);
          end;
          E.Bulges[i] := 0;
        end;
        for i := 0 to nb - 1 do
        begin
          d1 := m.ReadBD;
          if i < n then E.Bulges[i] := d1;
        end;
        for i := 0 to nid - 1 do m.ReadBL;
        if nw > 0 then
        begin
          SetLength(E.SWidths, n);
          SetLength(E.EWidths, n);
          for i := 0 to nw - 1 do
          begin
            d1 := m.ReadBD;
            d2 := m.ReadBD;
            if i < n then begin E.SWidths[i] := d1; E.EWidths[i] := d2; end;
          end;
          if E.ConstWidth = 0 then
            for i := 0 to n - 1 do E.ConstWidth := Max(E.ConstWidth, E.SWidths[i]);
        end;
        EntHandles;
        Keep;
      end;
    T_IMAGE, T_WIPEOUT:
      begin
        m.ReadBL;                                   // class version
        SetLength(E.Pts, 1);
        E.Pts[0] := m.Read3BD;
        E.UVec := m.Read3BD;
        E.VVec := m.Read3BD;
        E.ImageSize := m.Read2RD;
        m.ReadBS;                                   // display properties
        E.ClipOn := m.ReadB = 1;
        m.ReadRC; m.ReadRC; m.ReadRC;               // brightness, contrast, fade
        if Ver >= R2010 then m.ReadB;               // clip mode
        if m.ReadBS = 1 then
        begin
          AddPt(E.ClipPts, m.Read2RD);
          AddPt(E.ClipPts, m.Read2RD);
        end
        else
        begin
          n := m.ReadBL;
          if (n < 0) or (n > 100000) then Exit;
          for i := 0 to n - 1 do AddPt(E.ClipPts, m.Read2RD);
        end;
        EntHandles;
        if typ = T_IMAGE then
        begin
          E.Kind := ceImage;
          de.ImageDefH := h.ReadHRef(objH);
        end
        else WipeoutPts;
        Keep;
      end;
    T_HATCH:
      begin
        E.Kind := ceHatch;
        if Ver >= R2004 then
        begin
          E.IsGradient := m.ReadBL <> 0;
          m.ReadBL;
          E.GradAngle := m.ReadBD;
          E.GradShift := m.ReadBD;
          m.ReadBL;
          m.ReadBD;
          n := m.ReadBL;
          if (n < 0) or (n > 1000) then Exit;
          gc := 0;
          for i := 0 to n - 1 do
          begin
            m.ReadBD;
            cv := ReadCMC;
            if cv >= $1000000 then cv := cv and $FFFFFF
            else cv := Integer(XVAciColor(cv) and $FFFFFF);
            if gc = 0 then E.GradColor1 := cv else E.GradColor2 := cv;
            Inc(gc);
          end;
          E.GradName := T;
        end;
        E.Elevation := m.ReadBD;
        E.Extrusion := m.Read3BD;
        E.PatternName := T;
        E.Solid := m.ReadB = 1;
        m.ReadB;
        n := m.ReadBL;
        if (n < 0) or (n > 1000000) then Exit;
        derived := False;
        for i := 0 to n - 1 do
        begin
          L := Default(TCadLoop);
          fl := m.ReadBL;
          if (fl and 4) <> 0 then derived := True;
          L.IsPolyline := (fl and 2) <> 0;
          if not L.IsPolyline then
          begin
            nb := m.ReadBL;
            if (nb < 0) or (nb > 1000000) then Exit;
            for k := 0 to nb - 1 do
            begin
              ed := Default(TCadEdge);
              ed.CCW := True;
              case m.ReadRC of
                1:
                  begin
                    ed.Kind := cekLine;
                    ed.P1 := m.Read2RD;
                    ed.P2 := m.Read2RD;
                  end;
                2:
                  begin
                    ed.Kind := cekArc;
                    ed.Center := m.Read2RD;
                    ed.Radius := m.ReadBD;
                    ed.StartAng := RadToDeg_(m.ReadBD);
                    ed.EndAng := RadToDeg_(m.ReadBD);
                    ed.CCW := m.ReadB = 1;
                  end;
                3:
                  begin
                    ed.Kind := cekEllipse;
                    ed.Center := m.Read2RD;
                    ed.Major := m.Read2RD;
                    ed.Ratio := m.ReadBD;
                    ed.StartAng := RadToDeg_(m.ReadBD);
                    ed.EndAng := RadToDeg_(m.ReadBD);
                    ed.CCW := m.ReadB = 1;
                  end;
                4:
                  begin
                    ed.Kind := cekSpline;
                    ed.Degree := m.ReadBL;
                    bulges := m.ReadB = 1;           // rational
                    m.ReadB;                         // periodic
                    nw := m.ReadBL;
                    nid := m.ReadBL;
                    if (nw > 100000) or (nid > 100000) then Exit;
                    for w := 0 to nw - 1 do AddD(ed.Knots, m.ReadBD);
                    for w := 0 to nid - 1 do
                    begin
                      AddPt(ed.Ctrl, m.Read2RD);
                      if bulges then AddD(ed.Weights, m.ReadBD);
                    end;
                    if Ver >= R2010 then
                    begin
                      nf := m.ReadBL;
                      if nf > 100000 then Exit;
                      if nf > 0 then
                      begin
                        for w := 0 to nf - 1 do AddPt(ed.Fit, m.Read2RD);
                        m.Read2RD;
                        m.Read2RD;
                      end;
                    end;
                  end;
              else
                Exit;
              end;
              SetLength(L.Edges, Length(L.Edges) + 1);
              L.Edges[High(L.Edges)] := ed;
            end;
          end
          else
          begin
            bulges := m.ReadB = 1;
            L.Closed := m.ReadB = 1;
            nb := m.ReadBL;
            if (nb < 0) or (nb > 10000000) then Exit;
            SetLength(L.Pts, nb);
            SetLength(L.Bulges, nb);
            for k := 0 to nb - 1 do
            begin
              L.Pts[k] := m.Read2RD;
              if bulges then L.Bulges[k] := m.ReadBD else L.Bulges[k] := 0;
            end;
          end;
          m.ReadBL;                                  // boundary objects
          SetLength(E.Loops, Length(E.Loops) + 1);
          E.Loops[High(E.Loops)] := L;
          if m.Bad then Break;
        end;
        E.HatchStyle := m.ReadBS;
        m.ReadBS;
        if not E.Solid then
        begin
          m.ReadBD;
          m.ReadBD;
          m.ReadB;
          n := m.ReadBS;
          if (n < 0) or (n > 10000) then n := 0;
          for i := 0 to n - 1 do
          begin
            pl := Default(TCadPatLine);
            pl.Angle := RadToDeg_(m.ReadBD);
            pl.Base := m.Read2BD;
            pl.Offset := m.Read2BD;
            k := m.ReadBS;
            if (k < 0) or (k > 1000) then Break;
            for w := 0 to k - 1 do AddD(pl.Dashes, m.ReadBD);
            SetLength(E.PatLines, Length(E.PatLines) + 1);
            E.PatLines[High(E.PatLines)] := pl;
          end;
        end;
        if derived then m.ReadBD;
        EntHandles;
        Keep;
      end;
  end;
end;

// names, polyline vertices, containers
procedure TDwgReader.Assemble;
var
  i, j, k, bi: Integer;
  e: ^TDwgEnt;
  plIdx, insIdx, blockIdx: TDictionary<Int64, Integer>;
  br: TDwgBlockRec;
  pair: TPair<Int64, TDwgBlockRec>;
  lp: TPair<Int64, Integer>;
  msH, ltH: Int64;
  nm: string;

  function LayerName(H: Int64): string;
  var x: Integer;
  begin
    if LayerIdx.TryGetValue(H, x) then Result := Cad.Layers[x].Name else Result := '0';
  end;

  // the list an entity goes into: -1 model space, >= 0 a block, -2 none
  function Container(const D: TDwgEnt; Depth: Integer): Integer;
  var x: Integer;
  begin
    Result := -2;
    if Depth > 4 then Exit;
    case D.EntMode of
      2: Result := -1;
      1: Result := -2;
    else
      if D.Owner = msH then Result := -1
      else if blockIdx.TryGetValue(D.Owner, x) then Result := x
      else if insIdx.TryGetValue(D.Owner, x) then Result := Container(Ents[x], Depth + 1);
    end;
  end;

  procedure Put(const E: TCadEntity; Where: Integer);
  begin
    if Where = -1 then
    begin
      SetLength(Cad.Ents, Length(Cad.Ents) + 1);
      Cad.Ents[High(Cad.Ents)] := E;
    end
    else if Where >= 0 then
    begin
      SetLength(Cad.Blocks[Where].Ents, Length(Cad.Blocks[Where].Ents) + 1);
      Cad.Blocks[Where].Ents[High(Cad.Blocks[Where].Ents)] := E;
    end;
  end;

begin
  SetLength(Ents, NEnts);
  // linetypes of the layers
  for lp in LayerIdx do
    if LayerLTypeH.TryGetValue(lp.Key, ltH) and LTypeNames.TryGetValue(ltH, nm) then
      Cad.Layers[lp.Value].LType := nm;
  plIdx := TDictionary<Int64, Integer>.Create;
  insIdx := TDictionary<Int64, Integer>.Create;
  blockIdx := TDictionary<Int64, Integer>.Create;
  try
    // blocks
    msH := -1;
    for pair in BlockRecs do
    begin
      nm := UpperCase(pair.Value.Name);
      if nm = '*MODEL_SPACE' then msH := pair.Key
      else if Copy(nm, 1, 12) <> '*PAPER_SPACE' then
      begin
        bi := Cad.AddBlock(pair.Value.Name, pair.Value.Base);
        blockIdx.AddOrSetValue(pair.Key, bi);
      end;
    end;
    // names and indices
    for i := 0 to NEnts - 1 do
    begin
      e := @Ents[i];
      e.Ent.Layer := LayerName(e.LayerH);
      case e.LTFlags of
        0: e.Ent.LType := 'BYLAYER';
        1: e.Ent.LType := 'BYBLOCK';
        2: e.Ent.LType := 'CONTINUOUS';
      else
        if not LTypeNames.TryGetValue(e.LTypeH, nm) then nm := 'BYLAYER';
        e.Ent.LType := nm;
      end;
      if (e.StyleH <> 0) and StyleNames.TryGetValue(e.StyleH, nm) then e.Ent.Style := nm;
      if (e.BlockH <> 0) and BlockRecs.TryGetValue(e.BlockH, br) then e.Ent.Block := br.Name;
      if (e.ImageDefH <> 0) and ImageDefs.TryGetValue(e.ImageDefH, nm) then e.Ent.ImageFile := nm;
      case e.Typ of
        T_POLYLINE2D, T_POLYLINE3D: plIdx.AddOrSetValue(e.Handle, i);
        T_INSERT, T_MINSERT: insIdx.AddOrSetValue(e.Handle, i);
      end;
    end;
    // vertices into their polylines
    for i := 0 to NEnts - 1 do
    begin
      e := @Ents[i];
      if not (e.Typ in [T_VERTEX2D, T_VERTEX3D, T_VERTEXMESH, T_VERTEXPFACE]) then Continue;
      if not plIdx.TryGetValue(e.Owner, j) then Continue;
      if (e.Flags and 128) <> 0 then Continue;       // face records
      k := Length(Ents[j].Ent.Pts);
      SetLength(Ents[j].Ent.Pts, k + 1);
      Ents[j].Ent.Pts[k] := e.Ent.Pts[0];
      SetLength(Ents[j].Ent.Bulges, k + 1);
      Ents[j].Ent.Bulges[k] := e.Ent.Bulges[0];
      if (e.Ent.SWidths[0] > 0) and (Ents[j].Ent.ConstWidth = 0) then Ents[j].Ent.ConstWidth := e.Ent.SWidths[0];
    end;
    // into model space and blocks, in handle order
    for i := 0 to NEnts - 1 do
    begin
      e := @Ents[i];
      if e.Typ in [T_VERTEX2D, T_VERTEX3D, T_VERTEXMESH, T_VERTEXPFACE] then Continue;
      if e.Ent.Kind = ceNone then Continue;
      if Debug and (Container(e^, 0) = -2) then
        Log(Format('dropped %x type %d mode %d owner %x', [e.Handle, e.Typ, e.EntMode, e.Owner]));
      Put(e.Ent, Container(e^, 0));
    end;
  finally
    plIdx.Free;
    insIdx.Free;
    blockIdx.Free;
  end;
  Log(Format('entities: %d in model space, %d blocks', [Length(Cad.Ents), Length(Cad.Blocks)]));
  if Debug then
  begin
    for i := 0 to High(Cad.Ents) do
      with Cad.Ents[i] do
      begin
        Log(Format('MS %d layer=%s color=%d lt=%s pts=%d c=%.3f,%.3f r=%.3f text=%s block=%s', [Ord(Kind), Layer, Color,
          LType, Length(Pts), Center.X, Center.Y, Radius, Text, Block]));
        case Kind of
          cePolyline: if Length(Pts) > 0 then Log(Format('  PL %d closed=%d %.2f,%.2f,%.2f', [Length(Pts), Ord(Closed), Pts[0].X, Pts[0].Y, Bulges[0]]));
          ceLine: Log(Format('  LINE %.2f,%.2f %.2f,%.2f', [Pts[0].X, Pts[0].Y, Pts[1].X, Pts[1].Y]));
          ceText, ceMText: Log(Format('  TEXT %.2f,%.2f h=%.2f rot=%.2f', [Pts[0].X, Pts[0].Y, Height, Rotation]));
          ceInsert: Log(Format('  INSERT %.2f,%.2f sc=%.2f,%.2f rot=%.2f', [Pts[0].X, Pts[0].Y, Scale.X, Scale.Y, Rotation]));
          ceSpline: Log(Format('  SPLINE deg %d ctrl %d knots %d fit %d', [Degree, Length(Pts), Length(Knots), Length(FitPts)]));
          ceEllipse: Log(Format('  ELLIPSE %.2f,%.2f major %.2f,%.2f r=%.3f %.3f..%.3f', [Center.X, Center.Y, MajorAxis.X, MajorAxis.Y, Ratio, StartParam, EndParam]));
          ceHatch: Log(Format('  HATCH solid %d pattern %s paths %d', [Ord(Solid), PatternName, Length(Loops)]));
        end;
      end;
    for j := 0 to High(Cad.Blocks) do
      Log(Format('BLOCK %s: %d', [Cad.Blocks[j].Name, Length(Cad.Blocks[j].Ents)]));
  end;
end;
