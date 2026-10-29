unit uzoom;

{$mode delphi}{$H+}

// XelVectors zoom viewer: the main window (laid out in uzoom.lfm).
//
// The mouse wheel zooms around the cursor, dragging with the left or middle
// button pans, and files can be dropped on the window. Keys: + / - zoom,
// arrows pan, 0 fits the drawing, 1 shows it at 100 %.
//
// Only the visible part is rendered: for the duration of a render the
// document's view box is narrowed to the area under the window, so every zoom
// level costs the same as a window-sized picture.

interface

uses
  Classes, SysUtils, Math, Forms, Controls, Graphics, Dialogs, ExtCtrls, Menus, ComCtrls, StdCtrls, LCLType,
  XelVectors, XVModel, XVRenderCommon;

type

  { TZoomForm }

  TZoomForm = class(TForm)
    MainMenu: TMainMenu;
    MenuFile: TMenuItem;
    MenuOpen: TMenuItem;
    MenuSave: TMenuItem;
    MenuSep1: TMenuItem;
    MenuExit: TMenuItem;
    MenuView: TMenuItem;
    MenuZoomIn: TMenuItem;
    MenuZoomOut: TMenuItem;
    MenuSep2: TMenuItem;
    MenuFit: TMenuItem;
    MenuActual: TMenuItem;
    TopPanel: TPanel;
    BtnOpen: TButton;
    BtnZoomIn: TButton;
    BtnZoomOut: TButton;
    BtnFit: TButton;
    BtnActual: TButton;
    LabelZoom: TLabel;
    LabelHint: TLabel;
    View: TPaintBox;
    StatusBar: TStatusBar;
    OpenDialog: TOpenDialog;
    SaveDialog: TSaveDialog;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormDropFiles(Sender: TObject; const FileNames: array of string);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure OpenClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure ExitClick(Sender: TObject);
    procedure ZoomInClick(Sender: TObject);
    procedure ZoomOutClick(Sender: TObject);
    procedure FitClick(Sender: TObject);
    procedure ActualClick(Sender: TObject);
    procedure ViewPaint(Sender: TObject);
    procedure ViewResize(Sender: TObject);
    procedure ViewMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure ViewMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure ViewMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure ViewMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint;
      var Handled: Boolean);
  private
    FDoc: TXVDocument;
    FBmp: TBitmap;                 // the rendered view
    FZoom: Double;                 // window pixels per document unit
    FOrgX, FOrgY: Double;          // the document point at the window's top left
    FDragging: Boolean;
    FDragX, FDragY: Integer;
    FDragOrgX, FDragOrgY: Double;
    FFileName: string;
    function PageBox: TXVRect;
    function FitZoom: Double;
    procedure PanBy(DX, DY: Integer);
    procedure RenderView;
    procedure UpdateStatus;
  public
    procedure LoadFile(const FileName: string);
    procedure ZoomAt(Factor: Double; SX, SY: Integer);
    procedure SetZoom(AZoom: Double);
  end;

var
  ZoomForm: TZoomForm;

implementation

{$R *.lfm}

const
  ZOOM_STEP = 1.25;
  WORKSPACE = $FF808080;           // the area around the page

{ TZoomForm }

procedure TZoomForm.FormCreate(Sender: TObject);
begin
  FDoc := TXVDocument.Create;
  FBmp := TBitmap.Create;
  FZoom := 1;
  OpenDialog.Filter := XVFileFilter + '|All files|*.*';
end;

procedure TZoomForm.FormDestroy(Sender: TObject);
begin
  FDoc.Free;
  FBmp.Free;
end;

procedure TZoomForm.LoadFile(const FileName: string);
begin
  try
    FDoc.LoadFromFile(FileName);
  except
    on E: Exception do
    begin
      MessageDlg('Cannot open ' + ExtractFileName(FileName) + ':' + LineEnding + E.Message, mtError, [mbOK], 0);
      Exit;
    end;
  end;
  FFileName := FileName;
  Caption := 'XelVectors Zoom - ' + ExtractFileName(FileName);
  LabelHint.Visible := False;
  FitClick(nil);
end;

// the document's page: its view box, or its size when it has none
function TZoomForm.PageBox: TXVRect;
begin
  Result := FDoc.ViewBox;
  if Result.IsEmpty then Result := XVRect(0, 0, Max(FDoc.Width, 1), Max(FDoc.Height, 1));
end;

// the zoom that shows the whole page with a small margin
function TZoomForm.FitZoom: Double;
var r: TXVRect;
begin
  r := PageBox;
  Result := 0.95 * Min(View.Width / r.Width, View.Height / r.Height);
  if Result <= 0 then Result := 1;
end;

// zooms keeping the document point under the window point (SX, SY) in place
procedure TZoomForm.ZoomAt(Factor: Double; SX, SY: Integer);
var dx, dy: Double;
begin
  if FDoc.Count = 0 then Exit;
  dx := FOrgX + SX / FZoom;
  dy := FOrgY + SY / FZoom;
  FZoom := EnsureRange(FZoom * Factor, FitZoom / 20, FitZoom * 5000);
  FOrgX := dx - SX / FZoom;
  FOrgY := dy - SY / FZoom;
  RenderView;
end;

// a zoom level, around the middle of the window
procedure TZoomForm.SetZoom(AZoom: Double);
begin
  if FZoom > 0 then ZoomAt(AZoom / FZoom, View.Width div 2, View.Height div 2);
end;

// moves the drawing by (DX, DY) window pixels
procedure TZoomForm.PanBy(DX, DY: Integer);
begin
  if FDoc.Count = 0 then Exit;
  FOrgX := FOrgX - DX / FZoom;
  FOrgY := FOrgY - DY / FZoom;
  RenderView;
end;

// Renders the visible part of the document into FBmp. The view box becomes
// the area under the window; the transparent rendering is then laid over the
// page colour inside the page and the workspace colour outside it.
procedure TZoomForm.RenderView;
var
  saveVB, page: TXVRect;
  opt: TXVRenderOptions;
  r: TXVRaster;
  w, h, i, x, y, px0, py0, px1, py1: Integer;
  c, base, paper, a: Cardinal;
begin
  w := Max(1, View.Width);
  h := Max(1, View.Height);
  if FDoc.Count = 0 then
  begin
    FBmp.SetSize(w, h);
    FBmp.Canvas.Brush.Color := clGray;
    FBmp.Canvas.FillRect(0, 0, w, h);
    View.Invalidate;
    Exit;
  end;
  saveVB := FDoc.ViewBox;
  page := PageBox;
  FDoc.ViewBox := XVRect(FOrgX, FOrgY, FOrgX + w / FZoom, FOrgY + h / FZoom);
  try
    opt := XVDefaultRenderOptions;
    opt.Background := 0;
    opt.UseDocBackground := False;
    opt.KeepAspect := False;
    r := XVRenderRaster(FDoc, w, h, opt);
  finally
    FDoc.ViewBox := saveVB;
  end;
  // the page in window pixels
  px0 := Round((page.Left - FOrgX) * FZoom);
  py0 := Round((page.Top - FOrgY) * FZoom);
  px1 := Round((page.Right - FOrgX) * FZoom);
  py1 := Round((page.Bottom - FOrgY) * FZoom);
  paper := FDoc.Background;
  if (paper shr 24) = 0 then paper := XV_WHITE;
  // the drawing (straight alpha) over the page and the workspace
  for y := 0 to h - 1 do
    for x := 0 to w - 1 do
    begin
      i := y * w + x;
      c := r.Px[i];
      a := c shr 24;
      if a = 255 then Continue;
      if (x >= px0) and (x < px1) and (y >= py0) and (y < py1) then base := paper else base := WORKSPACE;
      if a = 0 then r.Px[i] := base
      else
        r.Px[i] := $FF000000 or
          (((((c shr 16) and $FF) * a + ((base shr 16) and $FF) * (255 - a)) div 255) shl 16) or
          (((((c shr 8) and $FF) * a + ((base shr 8) and $FF) * (255 - a)) div 255) shl 8) or
          (((c and $FF) * a + (base and $FF) * (255 - a)) div 255);
    end;
  XVRasterToBitmap(r, FBmp);
  View.Invalidate;
  UpdateStatus;
end;

procedure TZoomForm.UpdateStatus;
var z100: Double;
begin
  // 100 %: one document pixel (96 dpi) on one screen pixel
  z100 := FDoc.Width / Max(PageBox.Width, 1e-9);
  LabelZoom.Caption := Format('%.0f %%', [100 * FZoom / Max(z100, 1e-12)]);
  StatusBar.Panels[0].Text := FDoc.SourceFormat;
  StatusBar.Panels[1].Text := Format('%d elements', [FDoc.Count]);
  StatusBar.Panels[2].Text := Format('%.0f x %.0f px', [FDoc.Width, FDoc.Height]);
end;

procedure TZoomForm.ViewPaint(Sender: TObject);
begin
  if (FBmp.Width <> View.Width) or (FBmp.Height <> View.Height) then RenderView;
  View.Canvas.Draw(0, 0, FBmp);
end;

procedure TZoomForm.ViewResize(Sender: TObject);
begin
  RenderView;
end;

procedure TZoomForm.ViewMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if Button in [mbLeft, mbMiddle] then
  begin
    FDragging := True;
    FDragX := X;
    FDragY := Y;
    FDragOrgX := FOrgX;
    FDragOrgY := FOrgY;
    View.Cursor := crSizeAll;
  end;
end;

procedure TZoomForm.ViewMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
begin
  if FDragging then
  begin
    FOrgX := FDragOrgX - (X - FDragX) / FZoom;
    FOrgY := FDragOrgY - (Y - FDragY) / FZoom;
    RenderView;
  end;
  // the document point under the mouse
  if FDoc.Count > 0 then
    StatusBar.Panels[3].Text := Format('x %.2f  y %.2f', [FOrgX + X / FZoom, FOrgY + Y / FZoom]);
end;

procedure TZoomForm.ViewMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  FDragging := False;
  View.Cursor := crHandPoint;
end;

procedure TZoomForm.ViewMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint;
  var Handled: Boolean);
begin
  if WheelDelta > 0 then ZoomAt(ZOOM_STEP, MousePos.X, MousePos.Y)
  else ZoomAt(1 / ZOOM_STEP, MousePos.X, MousePos.Y);
  Handled := True;
end;

// files dropped from a file manager: the first one is opened
procedure TZoomForm.FormDropFiles(Sender: TObject; const FileNames: array of string);
begin
  if Length(FileNames) > 0 then LoadFile(FileNames[0]);
end;

procedure TZoomForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
const
  STEP = 50;                       // pixels per arrow key
begin
  case Key of
    VK_ADD, VK_OEM_PLUS: ZoomInClick(nil);
    VK_SUBTRACT, VK_OEM_MINUS: ZoomOutClick(nil);
    VK_0, VK_NUMPAD0: FitClick(nil);
    VK_1, VK_NUMPAD1: ActualClick(nil);
    VK_LEFT: PanBy(STEP, 0);
    VK_RIGHT: PanBy(-STEP, 0);
    VK_UP: PanBy(0, STEP);
    VK_DOWN: PanBy(0, -STEP);
  else
    Exit;
  end;
  Key := 0;
end;

procedure TZoomForm.OpenClick(Sender: TObject);
begin
  if OpenDialog.Execute then LoadFile(OpenDialog.FileName);
end;

procedure TZoomForm.SaveClick(Sender: TObject);
begin
  if FDoc.Count = 0 then Exit;
  SaveDialog.FileName := ChangeFileExt(ExtractFileName(FFileName), '.svg');
  if SaveDialog.Execute then FDoc.SaveToFile(SaveDialog.FileName);
end;

procedure TZoomForm.ExitClick(Sender: TObject);
begin
  Close;
end;

procedure TZoomForm.ZoomInClick(Sender: TObject);
begin
  ZoomAt(ZOOM_STEP, View.Width div 2, View.Height div 2);
end;

procedure TZoomForm.ZoomOutClick(Sender: TObject);
begin
  ZoomAt(1 / ZOOM_STEP, View.Width div 2, View.Height div 2);
end;

// the whole page, centred
procedure TZoomForm.FitClick(Sender: TObject);
var r: TXVRect;
begin
  if FDoc.Count = 0 then Exit;
  r := PageBox;
  FZoom := FitZoom;
  FOrgX := r.Left - (View.Width / FZoom - r.Width) / 2;
  FOrgY := r.Top - (View.Height / FZoom - r.Height) / 2;
  RenderView;
end;

// one document pixel on one screen pixel
procedure TZoomForm.ActualClick(Sender: TObject);
begin
  SetZoom(FDoc.Width / Max(PageBox.Width, 1e-9));
end;

end.
