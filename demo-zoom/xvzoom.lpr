program xvzoom;

{$mode delphi}{$H+}

// XelVectors zoom viewer: zoom with the mouse wheel, pan by dragging, open
// files by dropping them on the window.
//
// Usage: xvzoom [file]
// Window test: xvzoom --shot file window.png [zoom factor [pan x pan y]]
//   saves the window's image after fitting, zooming at the centre and panning.

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Classes, SysUtils, Forms, Controls, Graphics, uzoom;

var
  bmp: TBitmap;
  png: TPortableNetworkGraphic;
  f: Double;
begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TZoomForm, ZoomForm);
  if (ParamCount >= 3) and (ParamStr(1) = '--shot') then
  begin
    ZoomForm.Show;
    Application.ProcessMessages;
    ZoomForm.LoadFile(ParamStr(2));
    if ParamCount >= 4 then
    begin
      f := StrToFloatDef(ParamStr(4), 1, DefaultFormatSettings);
      ZoomForm.ZoomAt(f, ZoomForm.View.Width div 2, ZoomForm.View.Height div 2);
    end;
    if ParamCount >= 6 then
    begin
      // a drag of the mouse by (pan x, pan y)
      ZoomForm.ViewMouseDown(nil, mbLeft, [], 0, 0);
      ZoomForm.ViewMouseMove(nil, [ssLeft], StrToIntDef(ParamStr(5), 0), StrToIntDef(ParamStr(6), 0));
      ZoomForm.ViewMouseUp(nil, mbLeft, [], 0, 0);
    end;
    Application.ProcessMessages;
    bmp := ZoomForm.GetFormImage;
    png := TPortableNetworkGraphic.Create;
    try
      png.Assign(bmp);
      png.SaveToFile(ParamStr(3));
    finally
      png.Free;
      bmp.Free;
    end;
    Exit;
  end;
  if (ParamCount = 1) and FileExists(ParamStr(1)) then
  begin
    ZoomForm.Show;
    Application.ProcessMessages;
    ZoomForm.LoadFile(ParamStr(1));
  end;
  Application.Run;
end.
