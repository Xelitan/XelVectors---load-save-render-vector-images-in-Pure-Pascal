{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit xelvectors_pkg;

{$warn 5023 off : no warning about unused units}
interface

uses
  XelVectors, XVModel, XVImageCodec, XelInflate, XVZip, XVRenderCommon, 
  XVGdiPlusApi, XVRenderGDIPlus, XVRenderCairo, XVGdiPlay, XVCadModel, 
  XVReadSVG, XVReadWMF, XVReadEMF, XVReadCDR, XVReadMET, XVReadDXF, XVReadDWG, 
  XVReadCGM, XVReadODG, XVReadXAML, XVReadPS, XVWriteSVG, XVWriteEMF, 
  LazarusPackageIntf;

implementation

procedure Register;
begin
end;

initialization
  RegisterPackage('xelvectors_pkg', @Register);
end.
