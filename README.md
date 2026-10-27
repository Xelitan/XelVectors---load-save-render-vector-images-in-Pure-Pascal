# XelVectors

Reads vector formats, renders them (GDI+ on Windows, Cairo on Linux) and saves to SVG / EMF.


## Usage

Add to your project `xelvectors_pkg.lpk` and `XelVectors`:

```pascal
uses XelVectors;

var
  Doc: TXVDocument;
  Bmp: TBitmap;
begin
  Doc := TXVDocument.Create;
  Bmp := TBitmap.Create;
  try
    Doc.LoadFromFile('rysunek.dwg');      // detect format
    Bmp.SetSize(800, 600);
    XVDrawToBitmap(Doc, Bmp);             // GDI+ (Windows) / Cairo (Linux)
    Doc.SaveToFile('rysunek.svg');        // or .emf
  finally
    Bmp.Free;
    Doc.Free;
  end;
end;
```
