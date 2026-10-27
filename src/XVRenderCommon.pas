unit XVRenderCommon;

{$mode delphi}{$H+}
{$R-}{$Q-}

// XelVectors - pieces shared by the GDI+ and Cairo renderers: options, the
// view mapping, text run layout (anchors and continued runs) and raster
// conversions.

interface

uses
  SysUtils, Math, XVModel;

type
  TXVRenderOptions = record
    Background: TXVColor;          // painted first; 0 = transparent
    KeepAspect: Boolean;           // fit the view box into the target, centred
    AntiAlias: Boolean;
    UseDocBackground: Boolean;     // paint Doc.Background over Background
  end;

  // advance width of S in text space units (font size = Font.Size)
  TXVMeasureFunc = function(const Font: TXVFont; const S: string): Double of object;

function XVDefaultRenderOptions: TXVRenderOptions;

// document space -> target pixels
function XVViewMatrix(Doc: TXVDocument; W, H: Integer; KeepAspect: Boolean): TXVMatrix;

// Final matrix of every text element (others: identity): the anchor of each
// text chunk and the start of continued runs are resolved with Measure.
procedure XVLayoutTexts(Doc: TXVDocument; Measure: TXVMeasureFunc; out Layout: array of TXVMatrix); overload;
function XVLayoutTexts(Doc: TXVDocument; Measure: TXVMeasureFunc): TArray<TXVMatrix>; overload;

// width of a text run, honouring per-character positions
function XVRunWidth(const E: TXVElement; Measure: TXVMeasureFunc): Double;

procedure XVPremultiply(var R: TXVRaster);
procedure XVUnpremultiply(var R: TXVRaster);
procedure XVFillRaster(var R: TXVRaster; C: TXVColor);

implementation

function XVDefaultRenderOptions: TXVRenderOptions;
begin
  Result.Background := XV_WHITE;
  Result.KeepAspect := True;
  Result.AntiAlias := True;
  Result.UseDocBackground := True;
end;

function XVViewMatrix(Doc: TXVDocument; W, H: Integer; KeepAspect: Boolean): TXVMatrix;
var
  vb: TXVRect;
  sx, sy, s: Double;
begin
  vb := Doc.ViewBox;
  if vb.IsEmpty then vb := XVRect(0, 0, Max(Doc.Width, 1), Max(Doc.Height, 1));
  sx := W / vb.Width;
  sy := H / vb.Height;
  if KeepAspect then
  begin
    s := Min(sx, sy);
    Result := TXVMatrix.Make(s, 0, 0, s, (W - vb.Width * s) / 2 - vb.Left * s, (H - vb.Height * s) / 2 - vb.Top * s);
  end
  else
    Result := TXVMatrix.Make(sx, 0, 0, sy, -vb.Left * sx, -vb.Top * sy);
end;

function XVRunWidth(const E: TXVElement; Measure: TXVMeasureFunc): Double;
var ch: TStringArray;
begin
  if (Length(E.CharX) > 0) then
  begin
    ch := XVUtf8Chars(E.Text);
    if Length(ch) = 0 then Exit(0);
    if Length(E.CharX) >= Length(ch) then
      Exit(E.CharX[High(ch)] + Measure(E.Font, ch[High(ch)]));
  end;
  Result := Measure(E.Font, E.Text);
end;

procedure XVLayoutTexts(Doc: TXVDocument; Measure: TXVMeasureFunc; out Layout: array of TXVMatrix);
var
  i, j, k: Integer;
  run: array of Integer;
  adv: array of TXVPoint;
  tot, shift, pen, a: TXVPoint;
  m: TXVMatrix;
  w: Double;
begin
  for i := 0 to High(Layout) do Layout[i] := TXVMatrix.Identity;
  i := 0;
  while i < Doc.Count do
  begin
    if (Doc.Elements[i].Kind <> ekText) then begin Inc(i); Continue; end;
    // the chunk: this run and the continued runs after it
    run := nil;
    SetLength(run, 1);
    run[0] := i;
    j := i + 1;
    while j < Doc.Count do
    begin
      if Doc.Elements[j].Kind in [ekGroup, ekGroupEnd] then begin Inc(j); Continue; end;
      if (Doc.Elements[j].Kind = ekText) and Doc.Elements[j].Continued then
      begin
        SetLength(run, Length(run) + 1);
        run[High(run)] := j;
        Inc(j);
      end
      else Break;
    end;
    SetLength(adv, Length(run));
    tot := XVPt(0, 0);
    for k := 0 to High(run) do
    begin
      w := XVRunWidth(Doc.Elements[run[k]], Measure);
      adv[k] := Doc.Elements[run[k]].Matrix.ApplyVec(w, 0);
      tot.X := tot.X + adv[k].X; tot.Y := tot.Y + adv[k].Y;
      if k > 0 then
      begin
        // shifts of continued runs move the rest of the chunk too
        tot.X := tot.X + Doc.Elements[run[k]].Matrix.E;
        tot.Y := tot.Y + Doc.Elements[run[k]].Matrix.F;
      end;
    end;
    case Doc.Elements[i].Anchor of
      taMiddle: shift := XVPt(-tot.X / 2, -tot.Y / 2);
      taEnd: shift := XVPt(-tot.X, -tot.Y);
    else
      shift := XVPt(0, 0);
    end;
    m := Doc.Elements[i].Matrix;
    m.E := m.E + shift.X; m.F := m.F + shift.Y;
    Layout[i] := m;
    pen := XVPt(m.E + adv[0].X, m.F + adv[0].Y);
    for k := 1 to High(run) do
    begin
      m := Doc.Elements[run[k]].Matrix;
      a := XVPt(m.E, m.F);
      m.E := pen.X + a.X; m.F := pen.Y + a.Y;
      Layout[run[k]] := m;
      pen := XVPt(m.E + adv[k].X, m.F + adv[k].Y);
    end;
    i := run[High(run)] + 1;
  end;
end;

function XVLayoutTexts(Doc: TXVDocument; Measure: TXVMeasureFunc): TArray<TXVMatrix>;
begin
  SetLength(Result, Doc.Count);
  XVLayoutTexts(Doc, Measure, Result);
end;

procedure XVPremultiply(var R: TXVRaster);
var i: Integer; c, a: Cardinal;
begin
  for i := 0 to High(R.Px) do
  begin
    c := R.Px[i];
    a := c shr 24;
    if a = 255 then Continue;
    if a = 0 then begin R.Px[i] := 0; Continue; end;
    R.Px[i] := (a shl 24) or ((((c shr 16) and $FF) * a div 255) shl 16) or
      ((((c shr 8) and $FF) * a div 255) shl 8) or ((c and $FF) * a div 255);
  end;
end;

procedure XVUnpremultiply(var R: TXVRaster);
var i: Integer; c, a: Cardinal;
begin
  for i := 0 to High(R.Px) do
  begin
    c := R.Px[i];
    a := c shr 24;
    if (a = 255) or (a = 0) then Continue;
    R.Px[i] := (a shl 24) or (Min(255, ((c shr 16) and $FF) * 255 div a) shl 16) or
      (Min(255, ((c shr 8) and $FF) * 255 div a) shl 8) or Min(255, (c and $FF) * 255 div a);
  end;
end;

procedure XVFillRaster(var R: TXVRaster; C: TXVColor);
var i: Integer;
begin
  for i := 0 to High(R.Px) do R.Px[i] := C;
end;

end.
