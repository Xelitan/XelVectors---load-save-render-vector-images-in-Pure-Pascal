unit XVImageCodec;

{$mode delphi}{$H+}
{$R-}{$Q-}

// XelVectors - raster helpers: embedded PNG / JPEG / BMP / GIF / TIFF images
// (through the FCL image readers), device independent bitmaps of metafiles
// and PNG encoding for the SVG writer.

interface

uses
  SysUtils, Classes, Math, FPImage, FPReadPNG, FPReadJPEG, FPReadBMP, FPReadGIF, FPReadTiff,
  FPWritePNG, XVModel;

// Decodes a complete image file (PNG, JPEG, BMP, GIF, TIFF) held in memory.
function XVDecodeImage(const Data: TBytes; out Img: TXVImage): Boolean; overload;
function XVDecodeImage(const Data: TBytes; Ofs, Len: Integer; out Img: TXVImage): Boolean; overload;

// A DIB: BITMAPINFOHEADER (or BITMAPCOREHEADER) with its colour table at
// InfoOfs, the pixel rows at BitsOfs (BitsOfs < 0: right after the table).
function XVDecodeDIB(const D: TBytes; InfoOfs, InfoLen, BitsOfs, BitsLen: Integer; out Img: TXVImage): Boolean;

// PNG file bytes of an image
function XVEncodePNG(const Img: TXVImage): TBytes;

function XVBase64Encode(const D: TBytes): string;
function XVBase64Decode(const S: string): TBytes;

implementation

type
  TXVFPImage = class(TFPMemoryImage)
  end;

function FromFP(Src: TFPCustomImage; out Img: TXVImage): Boolean;
var
  x, y: Integer;
  c: TFPColor;
begin
  Img.W := Src.Width; Img.H := Src.Height;
  Result := (Img.W > 0) and (Img.H > 0);
  if not Result then begin Img.Px := nil; Exit; end;
  SetLength(Img.Px, Img.W * Img.H);
  for y := 0 to Img.H - 1 do
    for x := 0 to Img.W - 1 do
    begin
      c := Src.Colors[x, y];
      Img.Px[y * Img.W + x] := (Cardinal(c.Alpha shr 8) shl 24) or (Cardinal(c.Red shr 8) shl 16) or
        (Cardinal(c.Green shr 8) shl 8) or Cardinal(c.Blue shr 8);
    end;
end;

function XVDecodeImage(const Data: TBytes; Ofs, Len: Integer; out Img: TXVImage): Boolean;
var
  ms: TMemoryStream;
  im: TFPMemoryImage;
  rd: TFPCustomImageReader;
begin
  Result := False;
  Img.W := 0; Img.H := 0; Img.Px := nil;
  if (Ofs < 0) or (Len < 8) or (Ofs + Len > Length(Data)) then Exit;
  rd := nil;
  if (Data[Ofs] = $89) and (Data[Ofs + 1] = Ord('P')) and (Data[Ofs + 2] = Ord('N')) then rd := TFPReaderPNG.Create
  else if (Data[Ofs] = $FF) and (Data[Ofs + 1] = $D8) then rd := TFPReaderJPEG.Create
  else if (Data[Ofs] = Ord('B')) and (Data[Ofs + 1] = Ord('M')) then rd := TFPReaderBMP.Create
  else if (Data[Ofs] = Ord('G')) and (Data[Ofs + 1] = Ord('I')) and (Data[Ofs + 2] = Ord('F')) then rd := TFPReaderGIF.Create
  else if ((Data[Ofs] = Ord('I')) and (Data[Ofs + 1] = Ord('I'))) or ((Data[Ofs] = Ord('M')) and (Data[Ofs + 1] = Ord('M'))) then
    rd := TFPReaderTiff.Create;
  if rd = nil then Exit;
  ms := TMemoryStream.Create;
  im := TFPMemoryImage.Create(0, 0);
  try
    try
      ms.WriteBuffer(Data[Ofs], Len);
      ms.Position := 0;
      im.UsePalette := False;
      im.LoadFromStream(ms, rd);
      Result := FromFP(im, Img);
    except
      Result := False;
    end;
  finally
    im.Free;
    ms.Free;
    rd.Free;
  end;
end;

function XVDecodeImage(const Data: TBytes; out Img: TXVImage): Boolean;
begin
  Result := XVDecodeImage(Data, 0, Length(Data), Img);
end;

function LE16(const D: TBytes; p: Integer): Integer;
begin
  if (p < 0) or (p + 2 > Length(D)) then Exit(0);
  Result := D[p] or (D[p + 1] shl 8);
end;

function LE32(const D: TBytes; p: Integer): Cardinal;
begin
  if (p < 0) or (p + 4 > Length(D)) then Exit(0);
  Result := Cardinal(D[p]) or (Cardinal(D[p + 1]) shl 8) or (Cardinal(D[p + 2]) shl 16) or (Cardinal(D[p + 3]) shl 24);
end;

function MaskShift(m: Cardinal; out bits: Integer): Integer;
begin
  Result := 0; bits := 0;
  if m = 0 then Exit;
  while (m and 1) = 0 do begin m := m shr 1; Inc(Result); end;
  while (m and 1) = 1 do begin m := m shr 1; Inc(bits); end;
end;

function XVDecodeDIB(const D: TBytes; InfoOfs, InfoLen, BitsOfs, BitsLen: Integer; out Img: TXVImage): Boolean;
var
  hs, w, h, bpp, comp, ncol, stride, x, y, ty, i, k, bitsEnd: Integer;
  topDown, core, alphaUsed: Boolean;
  pal: array[0..255] of Cardinal;
  p, pix: Integer;
  v: Cardinal;
  rm, gm, bm, am: Cardinal;
  rs, gs, bs, as_, rb, gb, bb, ab: Integer;
  rle: TBytes;

  function Scale(val: Cardinal; bitsN: Integer): Cardinal;
  begin
    if bitsN <= 0 then Exit(0);
    if bitsN >= 8 then Result := val shr (bitsN - 8)
    else Result := (val * 255) div ((1 shl bitsN) - 1);
  end;

  // RLE4 / RLE8 into plain rows (bottom-up order kept)
  function Unrle(is4: Boolean): Boolean;
  var
    q, e, xx, yy, n, j, b2, st: Integer;
  begin
    st := ((w * bpp + 31) div 32) * 4;
    SetLength(rle, st * h);
    FillChar(rle[0], Length(rle), 0);
    q := BitsOfs; e := Min(Length(D), BitsOfs + BitsLen);
    xx := 0; yy := 0;
    while (q + 1 < e) and (yy < h) do
    begin
      n := D[q]; b2 := D[q + 1]; Inc(q, 2);
      if n > 0 then
      begin
        for j := 0 to n - 1 do
        begin
          if xx >= w then Break;
          if is4 then
          begin
            if (j and 1) = 0 then k := b2 shr 4 else k := b2 and 15;
            if (xx and 1) = 0 then rle[yy * st + xx shr 1] := rle[yy * st + xx shr 1] or (k shl 4)
            else rle[yy * st + xx shr 1] := rle[yy * st + xx shr 1] or k;
          end
          else rle[yy * st + xx] := b2;
          Inc(xx);
        end;
      end
      else
        case b2 of
          0: begin xx := 0; Inc(yy); end;
          1: Break;
          2: begin
               if q + 1 >= e then Break;
               Inc(xx, D[q]); Inc(yy, D[q + 1]); Inc(q, 2);
             end;
        else
          begin
            for j := 0 to b2 - 1 do
            begin
              if is4 then
              begin
                if q + j div 2 >= e then Break;
                if (j and 1) = 0 then k := D[q + j div 2] shr 4 else k := D[q + j div 2] and 15;
                if xx < w then
                begin
                  if (xx and 1) = 0 then rle[yy * st + xx shr 1] := rle[yy * st + xx shr 1] or (k shl 4)
                  else rle[yy * st + xx shr 1] := rle[yy * st + xx shr 1] or k;
                end;
              end
              else if (q + j < e) and (xx < w) then rle[yy * st + xx] := D[q + j];
              Inc(xx);
            end;
            if is4 then n := (b2 + 1) div 2 else n := b2;
            Inc(q, n + (n and 1));
          end;
        end;
    end;
    Result := True;
  end;

begin
  Result := False;
  Img.W := 0; Img.H := 0; Img.Px := nil;
  if (InfoOfs < 0) or (InfoOfs + 12 > Length(D)) then Exit;
  hs := LE32(D, InfoOfs);
  core := hs = 12;
  if core then
  begin
    w := LE16(D, InfoOfs + 4); h := SmallInt(LE16(D, InfoOfs + 6));
    bpp := LE16(D, InfoOfs + 10); comp := 0; ncol := 0;
  end
  else
  begin
    if hs < 16 then Exit;
    w := Integer(LE32(D, InfoOfs + 4)); h := Integer(LE32(D, InfoOfs + 8));
    bpp := LE16(D, InfoOfs + 14);
    if hs >= 20 then comp := LE32(D, InfoOfs + 16) else comp := 0;
    if hs >= 36 then ncol := LE32(D, InfoOfs + 32) else ncol := 0;
  end;
  topDown := h < 0;
  h := Abs(h);
  if (w <= 0) or (h <= 0) or (Int64(w) * h > 100000000) then Exit;
  // embedded JPEG / PNG (BI_JPEG, BI_PNG)
  if (comp = 4) or (comp = 5) then
  begin
    if BitsOfs < 0 then BitsOfs := InfoOfs + hs;
    Exit(XVDecodeImage(D, BitsOfs, Min(BitsLen, Length(D) - BitsOfs), Img));
  end;
  if not (bpp in [1, 2, 4, 8, 16, 24, 32]) then Exit;
  if (ncol = 0) and (bpp <= 8) then ncol := 1 shl bpp;
  if ncol > 256 then ncol := 256;
  FillChar(pal, SizeOf(pal), 0);
  p := InfoOfs + hs;
  // masks of BI_BITFIELDS follow a 40-byte header
  rm := 0; gm := 0; bm := 0; am := 0;
  if comp = 3 then
  begin
    if hs >= 52 then
    begin
      rm := LE32(D, InfoOfs + 40); gm := LE32(D, InfoOfs + 44); bm := LE32(D, InfoOfs + 48);
      if hs >= 56 then am := LE32(D, InfoOfs + 52);
    end
    else
    begin
      rm := LE32(D, p); gm := LE32(D, p + 4); bm := LE32(D, p + 8);
      Inc(p, 12);
    end;
  end;
  if bpp <= 8 then
  begin
    for i := 0 to ncol - 1 do
      if core then
        pal[i] := $FF000000 or (Cardinal(D[Min(p + i * 3 + 2, High(D))]) shl 16) or
          (Cardinal(D[Min(p + i * 3 + 1, High(D))]) shl 8) or D[Min(p + i * 3, High(D))]
      else
        pal[i] := $FF000000 or (LE32(D, p + i * 4) and $FFFFFF);
    if core then Inc(p, ncol * 3) else Inc(p, ncol * 4);
  end;
  if BitsOfs < 0 then BitsOfs := p;
  if BitsLen <= 0 then BitsLen := Length(D) - BitsOfs;
  stride := ((w * bpp + 31) div 32) * 4;
  rle := nil;
  if (comp = 1) and (bpp = 8) then Unrle(False)
  else if (comp = 2) and (bpp = 4) then Unrle(True)
  else if (comp <> 0) and (comp <> 3) then Exit;
  if bpp = 16 then
  begin
    if comp <> 3 then begin rm := $7C00; gm := $03E0; bm := $001F; end;
  end
  else if (bpp = 32) and (comp <> 3) then begin rm := $FF0000; gm := $FF00; bm := $FF; end;
  rs := MaskShift(rm, rb); gs := MaskShift(gm, gb); bs := MaskShift(bm, bb); as_ := MaskShift(am, ab);
  Img.W := w; Img.H := h;
  SetLength(Img.Px, w * h);
  bitsEnd := Min(Length(D), BitsOfs + BitsLen);
  alphaUsed := False;
  for y := 0 to h - 1 do
  begin
    if topDown then ty := y else ty := h - 1 - y;
    if rle <> nil then pix := y * stride else pix := BitsOfs + y * stride;
    for x := 0 to w - 1 do
    begin
      v := 0;
      if rle <> nil then
      begin
        if bpp = 8 then begin if pix + x < Length(rle) then v := pal[rle[pix + x]]; end
        else if pix + x shr 1 < Length(rle) then
          if (x and 1) = 0 then v := pal[rle[pix + x shr 1] shr 4] else v := pal[rle[pix + x shr 1] and 15];
      end
      else
        case bpp of
          1: if pix + x shr 3 < bitsEnd then v := pal[(D[pix + x shr 3] shr (7 - x and 7)) and 1];
          2: if pix + x shr 2 < bitsEnd then v := pal[(D[pix + x shr 2] shr (6 - 2 * (x and 3))) and 3];
          4: if pix + x shr 1 < bitsEnd then
               if (x and 1) = 0 then v := pal[D[pix + x shr 1] shr 4] else v := pal[D[pix + x shr 1] and 15];
          8: if pix + x < bitsEnd then v := pal[D[pix + x]];
          16: if pix + 2 * x + 1 < bitsEnd then
              begin
                k := D[pix + 2 * x] or (D[pix + 2 * x + 1] shl 8);
                v := $FF000000 or (Scale((k and rm) shr rs, rb) shl 16) or (Scale((k and gm) shr gs, gb) shl 8) or
                  Scale((k and bm) shr bs, bb);
              end;
          24: if pix + 3 * x + 2 < bitsEnd then
                v := $FF000000 or D[pix + 3 * x] or (D[pix + 3 * x + 1] shl 8) or (D[pix + 3 * x + 2] shl 16);
          32: if pix + 4 * x + 3 < bitsEnd then
              begin
                k := Integer(LE32(D, pix + 4 * x));
                v := (Scale((Cardinal(k) and rm) shr rs, rb) shl 16) or (Scale((Cardinal(k) and gm) shr gs, gb) shl 8) or
                  Scale((Cardinal(k) and bm) shr bs, bb);
                if am <> 0 then
                begin
                  v := v or (Scale((Cardinal(k) and am) shr as_, ab) shl 24);
                  alphaUsed := True;
                end
                else v := v or (Cardinal(D[pix + 4 * x + 3]) shl 24);
              end;
        end;
      Img.Px[ty * w + x] := v;
    end;
  end;
  // a 32-bit DIB whose alpha bytes are all zero is opaque
  if bpp = 32 then
  begin
    alphaUsed := False;
    for i := 0 to High(Img.Px) do
      if (Img.Px[i] shr 24) <> 0 then begin alphaUsed := True; Break; end;
    if not alphaUsed then
      for i := 0 to High(Img.Px) do Img.Px[i] := Img.Px[i] or $FF000000;
  end;
  Result := True;
end;

function XVEncodePNG(const Img: TXVImage): TBytes;
var
  im: TFPMemoryImage;
  wr: TFPWriterPNG;
  ms: TMemoryStream;
  x, y: Integer;
  c: Cardinal;
  fc: TFPColor;
begin
  Result := nil;
  if (Img.W <= 0) or (Img.H <= 0) then Exit;
  im := TFPMemoryImage.Create(Img.W, Img.H);
  wr := TFPWriterPNG.Create;
  ms := TMemoryStream.Create;
  try
    im.UsePalette := False;
    for y := 0 to Img.H - 1 do
      for x := 0 to Img.W - 1 do
      begin
        c := Img.Px[y * Img.W + x];
        fc.Red := ((c shr 16) and $FF) * $101;
        fc.Green := ((c shr 8) and $FF) * $101;
        fc.Blue := (c and $FF) * $101;
        fc.Alpha := (c shr 24) * $101;
        im.Colors[x, y] := fc;
      end;
    wr.UseAlpha := True;
    wr.Indexed := False;
    wr.WordSized := False;
    im.SaveToStream(ms, wr);
    SetLength(Result, ms.Size);
    if ms.Size > 0 then Move(ms.Memory^, Result[0], ms.Size);
  finally
    ms.Free;
    wr.Free;
    im.Free;
  end;
end;

const
  B64: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function XVBase64Encode(const D: TBytes): string;
var
  i, n, k: Integer;
  v: Cardinal;
begin
  n := Length(D);
  SetLength(Result, ((n + 2) div 3) * 4);
  k := 1;
  i := 0;
  while i < n do
  begin
    v := Cardinal(D[i]) shl 16;
    if i + 1 < n then v := v or (Cardinal(D[i + 1]) shl 8);
    if i + 2 < n then v := v or D[i + 2];
    Result[k] := B64[(v shr 18) and 63 + 1];
    Result[k + 1] := B64[(v shr 12) and 63 + 1];
    if i + 1 < n then Result[k + 2] := B64[(v shr 6) and 63 + 1] else Result[k + 2] := '=';
    if i + 2 < n then Result[k + 3] := B64[v and 63 + 1] else Result[k + 3] := '=';
    Inc(k, 4);
    Inc(i, 3);
  end;
end;

function XVBase64Decode(const S: string): TBytes;
var
  i, n, bits: Integer;
  v: Cardinal;
  c: Char;
  d: Integer;
begin
  SetLength(Result, Length(S) * 3 div 4 + 3);
  n := 0; v := 0; bits := 0;
  for i := 1 to Length(S) do
  begin
    c := S[i];
    case c of
      'A'..'Z': d := Ord(c) - Ord('A');
      'a'..'z': d := Ord(c) - Ord('a') + 26;
      '0'..'9': d := Ord(c) - Ord('0') + 52;
      '+', '-': d := 62;
      '/', '_': d := 63;
    else
      Continue;
    end;
    v := (v shl 6) or Cardinal(d);
    Inc(bits, 6);
    if bits >= 8 then
    begin
      Dec(bits, 8);
      Result[n] := (v shr bits) and $FF;
      Inc(n);
    end;
  end;
  SetLength(Result, n);
end;

end.
