unit XelVectors;

{$mode delphi}{$H+}

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Description:	XelVectors - vector graphics for Lazarus                      //
// Version:	0.1                                                           //
// Date:	27-OCT-2026                                                   //
// License:     MIT                                                           //
// Target:	Win64 (GDI+), Linux64 (Cairo), Free Pascal / Lazarus          //
// Copyright:	(c) 2026 Xelitan.com.                                         //
//		All rights reserved.                                          //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
// One unit to use: it registers every reader and writer and draws documents
// on LCL bitmaps.
//
//   Doc := TXVDocument.Create;
//   Doc.LoadFromFile('drawing.cdr');          // SVG WMF EMF CDR MET DXF DWG
//                                             // CGM ODG XAML PS EPS ...
//   XVDrawToBitmap(Doc, Bitmap);              // GDI+ on Windows, Cairo on Linux
//   Doc.SaveToFile('drawing.svg');            // or .emf
//
// The document (XVModel) is a flat list of records: paths, texts, images and
// group brackets, with gradients, patterns, images and clip paths in arrays.

interface

uses
  Classes, SysUtils, Math, Graphics, GraphType, IntfGraphics, LCLType, FPImage,
  XVModel, XVRenderCommon, XVImageCodec,
  XVRenderGDIPlus, XVRenderCairo,
  // readers (they register themselves)
  XVReadSVG, XVReadWMF, XVReadEMF, XVReadCDR, XVReadMET, XVReadDXF, XVReadDWG, XVReadCGM,
  XVReadODG, XVReadXAML, XVReadPS,
  // writers
  XVWriteSVG, XVWriteEMF;

type
  TXVDocument = XVModel.TXVDocument;
  TXVRenderOptions = XVRenderCommon.TXVRenderOptions;
  TXVRaster = XVModel.TXVRaster;
  TXVColor = XVModel.TXVColor;
  EXVError = XVModel.EXVError;

  TXVRenderer = (xrAuto, xrGdiPlus, xrCairo);

var
  // the renderer XVRender* use; xrAuto: GDI+ on Windows, Cairo elsewhere
  XVRenderer: TXVRenderer = xrAuto;

function XVDefaultRenderOptions: TXVRenderOptions;

// Renders into a raster of the given size (the document is fitted into it).
function XVRenderRaster(Doc: TXVDocument; AWidth, AHeight: Integer; const Opt: TXVRenderOptions): TXVRaster; overload;
function XVRenderRaster(Doc: TXVDocument; AWidth, AHeight: Integer): TXVRaster; overload;

// Draws the document on the bitmap. A bitmap without a size gets the
// document's natural size (96 dpi). The bitmap becomes 32-bit with alpha
// when the background is transparent.
procedure XVDrawToBitmap(Doc: TXVDocument; Bmp: TBitmap; const Opt: TXVRenderOptions); overload;
procedure XVDrawToBitmap(Doc: TXVDocument; Bmp: TBitmap); overload;

// Loads a file and draws it on Bmp, fitted into MaxWidth x MaxHeight
// (0 = natural size). Returns the natural size of the drawing.
function XVLoadToBitmap(const FileName: string; Bmp: TBitmap; MaxWidth: Integer = 0; MaxHeight: Integer = 0): TPoint;

procedure XVRasterToBitmap(const R: TXVRaster; Bmp: TBitmap);

// Converts a file into another format by its extension (.svg, .emf).
procedure XVConvertFile(const SrcFile, DstFile: string);

// '*.svg;*.svgz;*.wmf;...' for open dialogs
function XVFileFilter: string;

type
  { TXVDocumentHelper }

  TXVDocumentHelper = class helper for TXVDocument
    procedure DrawTo(Bmp: TBitmap); overload;
    procedure DrawTo(Bmp: TBitmap; const Opt: TXVRenderOptions); overload;
  end;

implementation

function XVDefaultRenderOptions: TXVRenderOptions;
begin
  Result := XVRenderCommon.XVDefaultRenderOptions;
end;

function XVRenderRaster(Doc: TXVDocument; AWidth, AHeight: Integer; const Opt: TXVRenderOptions): TXVRaster;
var
  ok: Boolean;
  rr: TXVRenderer;
begin
  Result.W := Max(1, AWidth);
  Result.H := Max(1, AHeight);
  Result.Px := nil;
  rr := XVRenderer;
  if rr = xrAuto then
  begin
    {$IFDEF MSWINDOWS}rr := xrGdiPlus;{$ELSE}rr := xrCairo;{$ENDIF}
  end;
  if rr = xrGdiPlus then ok := XVRenderWithGdiPlus(Doc, Result, Opt)
  else ok := XVRenderWithCairo(Doc, Result, Opt);
  if not ok then
  begin
    // the other renderer, if this build has it
    if rr = xrGdiPlus then ok := XVRenderWithCairo(Doc, Result, Opt)
    else ok := XVRenderWithGdiPlus(Doc, Result, Opt);
  end;
  if not ok then raise EXVError.Create('XelVectors: no renderer available');
end;

function XVRenderRaster(Doc: TXVDocument; AWidth, AHeight: Integer): TXVRaster;
begin
  Result := XVRenderRaster(Doc, AWidth, AHeight, XVDefaultRenderOptions);
end;

procedure XVRasterToBitmap(const R: TXVRaster; Bmp: TBitmap);
var
  img: TLazIntfImage;
  desc: TRawImageDescription;
  y: Integer;
  line: PByte;
begin
  img := TLazIntfImage.Create(0, 0);
  try
    // BGRA, top-down: the byte order of the raster's $AARRGGBB values
    desc.Init_BPP32_B8G8R8A8_BIO_TTB(R.W, R.H);
    img.DataDescription := desc;
    for y := 0 to R.H - 1 do
    begin
      line := img.GetDataLineStart(y);
      Move(R.Px[y * R.W], line^, R.W * 4);
    end;
    Bmp.LoadFromIntfImage(img);
  finally
    img.Free;
  end;
end;

procedure XVDrawToBitmap(Doc: TXVDocument; Bmp: TBitmap; const Opt: TXVRenderOptions);
var
  r: TXVRaster;
  w, h: Integer;
begin
  w := Bmp.Width; h := Bmp.Height;
  if (w <= 0) or (h <= 0) then
  begin
    w := Max(1, Round(Doc.Width));
    h := Max(1, Round(Doc.Height));
  end;
  r := XVRenderRaster(Doc, w, h, Opt);
  XVRasterToBitmap(r, Bmp);
end;

procedure XVDrawToBitmap(Doc: TXVDocument; Bmp: TBitmap);
begin
  XVDrawToBitmap(Doc, Bmp, XVDefaultRenderOptions);
end;

function XVLoadToBitmap(const FileName: string; Bmp: TBitmap; MaxWidth: Integer; MaxHeight: Integer): TPoint;
var
  doc: TXVDocument;
  w, h, s: Double;
begin
  doc := TXVDocument.Create;
  try
    doc.LoadFromFile(FileName);
    w := Max(1, doc.Width); h := Max(1, doc.Height);
    Result := Point(Round(w), Round(h));
    s := 1;
    if (MaxWidth > 0) and (w * s > MaxWidth) then s := MaxWidth / w;
    if (MaxHeight > 0) and (h * s > MaxHeight) then s := MaxHeight / h;
    Bmp.SetSize(Max(1, Round(w * s)), Max(1, Round(h * s)));
    XVDrawToBitmap(doc, Bmp);
  finally
    doc.Free;
  end;
end;

procedure XVConvertFile(const SrcFile, DstFile: string);
var doc: TXVDocument;
begin
  doc := TXVDocument.Create;
  try
    doc.LoadFromFile(SrcFile);
    doc.SaveToFile(DstFile);
  finally
    doc.Free;
  end;
end;

function XVFileFilter: string;
begin
  Result := 'Vector drawings|' + XVSupportedExtensions;
end;

{ TXVDocumentHelper }

procedure TXVDocumentHelper.DrawTo(Bmp: TBitmap);
begin
  XVDrawToBitmap(Self, Bmp);
end;

procedure TXVDocumentHelper.DrawTo(Bmp: TBitmap; const Opt: TXVRenderOptions);
begin
  XVDrawToBitmap(Self, Bmp, Opt);
end;

end.
