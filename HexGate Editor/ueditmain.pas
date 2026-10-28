unit UEditMain;

{ HexGate Editor window.

  Picture: the HexGate renderer itself (uhexbackground.pas: BGRABitmap on all
  CPU cores) shown through OpenGL with vsync, exactly like HexGate. An
  autopilot flies through gates made with the file's game rules; hold the
  left mouse button on the picture to steer yourself.

  Right side:
    Settings  every value of the file by group: slider + number for numbers,
              colour button + alpha for colours. The picture follows at once
              (caches are rebuilt shortly after the last change).
    Images    the images stored in the file: sprite atlas, background,
              vignette, reference frame (refreshed by Save).
    File      what the file holds (sections, counts, readme).

  Menu File: Open, Save, Save As, Exit. Save re-bakes all images of the file
  from the edited values, so other programs (HexGate Simulator, your own
  tools) see the same graphics. }

{$mode objfpc}{$H+}

interface

uses
  {$IFDEF WINDOWS}Windows, MMSystem,{$ENDIF}
  Classes, SysUtils, Math, Forms, Controls, Graphics, GraphType, ExtCtrls, StdCtrls,
  ComCtrls, Menus, Dialogs, Spin, LCLType, GL, OpenGLContext, BGRABitmap,
  BGRABitmapTypes, UHexBackground, UGfxFile, UGfxBake;

type
  TEdRow = record
    Group, Name, Hint: string;
    IsColor: boolean;
    PValue: PSingle;
    PColor: PBGRAPixel;
    VMin, VMax: single;
    Decimals: integer;
    Effects: TInvalidateSet;
  end;

  TGate = record
    Z, GX, GY, GR: single;
  end;

  { TEditorForm }

  TEditorForm = class(TForm)
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FHex: THexBackground;
    FData: TGfxFile;
    FUntitled, FModified: boolean;
    // ---- controls
    FMenu: TMainMenu;
    FMiPanel, FMiPause, FMiGates: TMenuItem;
    FStatus: TStatusBar;
    FSide: TPanel;
    FSplit: TSplitter;
    FPages: TPageControl;
    FGroupBox: TComboBox;
    FRowBox: TScrollBox;
    FHintMemo: TMemo;
    FImageBox: TComboBox;
    FImageInfo: TLabel;
    FImage: TImage;
    FSummary: TMemo;
    FOpenDlg: TOpenDialog;
    FSaveDlg: TSaveDialog;
    // ---- rows
    FRows: array of TEdRow;
    FGroups: TStringList;
    FSyncing: boolean;
    FBuiltW: integer;                // FRowBox width the rows were laid out for
    FPendingFx: TInvalidateSet;
    FLastEdit: QWord;
    // ---- output (as in HexGate)
    FFrame: TBGRABitmap;
    FGL: TOpenGLControl;
    FView: TPaintBox;
    FOutput: TControl;
    FUseGL, FGLReady, FVSyncSet, FFullScreen: boolean;
    FTexture: GLuint;
    FTexW, FTexH: integer;
    FSavedBounds: TRect;
    // ---- simulation
    FPaused, FGatesOn, FSteering: boolean;
    FCamSpeed: single;               // camera.speed of the file (the autopilot drives the engine's)
    FLevel: integer;
    FMouseX, FMouseY: single;
    FGates: array of TGate;
    FPX, FPY, FVX, FVY, FSpeed, FLastGateZ, FLastGX, FLastGY: single;
    FPassed, FHits: integer;
    FFrames: integer;
    FFps, FLastTick, FFpsStart: double;
    FImagesStale: boolean;
    // building the window
    procedure BuildMenu;
    procedure BuildSide;
    function AddItem(AParent: TMenuItem; const ACaption: string; AShortCut: TShortCut;
      AOnClick: TNotifyEvent): TMenuItem;
    // file
    procedure LoadFile(const FileName: string);
    procedure NewFromDefaults;
    procedure AfterLoad;
    function DoSave(const FileName: string): boolean;
    function SaveAs: boolean;
    function ConfirmDiscard: boolean;
    procedure SetModified(V: boolean);
    procedure UpdateCaption;
    procedure ShowImage;
    // rows
    procedure BuildRows;
    procedure AddGameRow(const AName, AHint: string; P: PSingle; AMin, AMax: single; ADecimals: integer);
    procedure ShowGroup;
    procedure ShowRowHint(Index: integer);
    procedure RowChanged(Index: integer);
    function TrackPos(Index: integer): integer;
    // events
    procedure MiOpen(Sender: TObject);
    procedure MiSave(Sender: TObject);
    procedure MiSaveAs(Sender: TObject);
    procedure MiExit(Sender: TObject);
    procedure MiPanel(Sender: TObject);
    procedure MiFullScreen(Sender: TObject);
    procedure MiPng(Sender: TObject);
    procedure MiPause(Sender: TObject);
    procedure MiGates(Sender: TObject);
    procedure MiLevelUp(Sender: TObject);
    procedure MiLevelDown(Sender: TObject);
    procedure MiRestart(Sender: TObject);
    procedure MiReload(Sender: TObject);
    procedure MiKeys(Sender: TObject);
    procedure GroupChange(Sender: TObject);
    procedure ImageChange(Sender: TObject);
    procedure PageChange(Sender: TObject);
    procedure TrackChange(Sender: TObject);
    procedure SpinChange(Sender: TObject);
    procedure ColorChange(Sender: TObject);
    procedure AlphaChange(Sender: TObject);
    procedure RowEnter(Sender: TObject);
    procedure RowBoxResize(Sender: TObject);
    procedure RowMouseEnter(Sender: TObject);
    // frames
    procedure AppIdle(Sender: TObject; var Done: boolean);
    procedure DoFrame;
    procedure Present;
    procedure PresentGL;
    procedure UseGDI;
    procedure GLPaint(Sender: TObject);
    procedure ViewPaint(Sender: TObject);
    procedure OutputMouseMove(Sender: TObject; Shift: TShiftState; X, Y: integer);
    procedure OutputMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: integer);
    procedure OutputMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: integer);
    // autopilot
    procedure ResetFlight;
    procedure SpawnGates;
    procedure Fly(dt: single);
  end;

var
  EditorForm: TEditorForm;

implementation

{$R *.lfm}

const
  AppName = 'HexGate Editor';
  FallbackFps = 60;
  MaxLevel = 80;
  RowH = 30;
  TrackSteps = 1000;
  GameGroup = 'Game rules (autopilot)';

function ToColor(const P: TBGRAPixel): TColor;
begin
  Result := RGBToColor(P.red, P.green, P.blue);
end;

{ ================================================================ window }

procedure TEditorForm.FormCreate(Sender: TObject);
var
  FileName: string;
begin
  UseNiceFloats;                     // saved numbers read 1.1, not 1.10000000000000E+000
  Caption := AppName;
  FGroups := TStringList.Create;
  FHex := THexBackground.Create;
  FHex.AsyncSprites := True;
  FData := TGfxFile.Create;
  FFrame := TBGRABitmap.Create(16, 16, BGRABlack);
  FGatesOn := True;

  FOpenDlg := TOpenDialog.Create(Self);
  FOpenDlg.Title := 'Open HexGate graphics file';
  FOpenDlg.Filter := 'HexGate graphics (*.json)|*.json|All files (*.*)|*.*';
  FOpenDlg.Options := FOpenDlg.Options + [ofFileMustExist];
  FSaveDlg := TSaveDialog.Create(Self);
  FSaveDlg.Title := 'Save HexGate graphics file as';
  FSaveDlg.Filter := FOpenDlg.Filter;
  FSaveDlg.DefaultExt := 'json';
  FSaveDlg.Options := FSaveDlg.Options + [ofOverwritePrompt];

  BuildMenu;
  FStatus := TStatusBar.Create(Self);
  FStatus.Parent := Self;
  FStatus.SimplePanel := False;
  with FStatus.Panels.Add do Width := 330;
  with FStatus.Panels.Add do Width := 330;
  with FStatus.Panels.Add do Width := 380;
  FStatus.Panels.Add;
  BuildSide;

  // ---- picture (OpenGL with vsync, GDI if OpenGL is not available)
  FView := TPaintBox.Create(Self);
  FView.Parent := Self;
  FView.Align := alClient;
  FView.Visible := False;
  FView.OnPaint := @ViewPaint;
  FView.OnMouseMove := @OutputMouseMove;
  FView.OnMouseDown := @OutputMouseDown;
  FView.OnMouseUp := @OutputMouseUp;
  FOutput := FView;
  FUseGL := True;
  try
    FGL := TOpenGLControl.Create(Self);
    FGL.Parent := Self;
    FGL.Align := alClient;
    FGL.AutoResizeViewport := False;
    FGL.DepthBits := 0;
    FGL.OnPaint := @GLPaint;
    FGL.OnMouseMove := @OutputMouseMove;
    FGL.OnMouseDown := @OutputMouseDown;
    FGL.OnMouseUp := @OutputMouseUp;
    FOutput := FGL;
  except
    UseGDI;
  end;

  // ---- first file: the parameter, else hexgate_graphics.json next to the program
  FileName := ParamStr(1);
  if FileName = '' then FileName := ExtractFilePath(Application.ExeName) + 'hexgate_graphics.json';
  if FileExists(FileName) then
    LoadFile(FileName)
  else
    NewFromDefaults;
  if FData.Root = nil then NewFromDefaults;

  {$IFDEF WINDOWS}
  timeBeginPeriod(1);
  {$ENDIF}
  FLastTick := NowMs;
  FFpsStart := FLastTick;
  Application.AddOnIdleHandler(@AppIdle);
end;

procedure TEditorForm.FormDestroy(Sender: TObject);
begin
  Application.RemoveOnIdleHandler(@AppIdle);
  {$IFDEF WINDOWS}
  timeEndPeriod(1);
  {$ENDIF}
  FData.Free;
  FFrame.Free;
  FHex.Free;
  FGroups.Free;
end;

procedure TEditorForm.FormCloseQuery(Sender: TObject; var CanClose: boolean);
begin
  CanClose := ConfirmDiscard;
end;

function TEditorForm.AddItem(AParent: TMenuItem; const ACaption: string; AShortCut: TShortCut;
  AOnClick: TNotifyEvent): TMenuItem;
begin
  Result := TMenuItem.Create(FMenu);
  Result.Caption := ACaption;
  Result.ShortCut := AShortCut;
  Result.OnClick := AOnClick;
  AParent.Add(Result);
end;

procedure TEditorForm.BuildMenu;
var
  M: TMenuItem;
begin
  FMenu := TMainMenu.Create(Self);
  Menu := FMenu;

  M := AddItem(FMenu.Items, '&File', 0, nil);
  AddItem(M, '&Open...', ShortCut(VK_O, [ssCtrl]), @MiOpen);
  AddItem(M, '&Save', ShortCut(VK_S, [ssCtrl]), @MiSave);
  AddItem(M, 'Save &As...', ShortCut(VK_S, [ssCtrl, ssShift]), @MiSaveAs);
  AddItem(M, '-', 0, nil);
  AddItem(M, 'E&xit', ShortCut(VK_F4, [ssAlt]), @MiExit);

  M := AddItem(FMenu.Items, '&View', 0, nil);
  FMiPanel := AddItem(M, '&Edit panel', ShortCut(VK_F4, []), @MiPanel);
  FMiPanel.Checked := True;
  AddItem(M, '&Full screen', ShortCut(VK_F11, []), @MiFullScreen);
  AddItem(M, 'Save picture as &PNG', ShortCut(VK_F12, []), @MiPng);

  M := AddItem(FMenu.Items, '&Simulation', 0, nil);
  FMiPause := AddItem(M, '&Pause', ShortCut(VK_F5, []), @MiPause);
  FMiGates := AddItem(M, '&Gates', ShortCut(VK_F6, []), @MiGates);
  FMiGates.Checked := True;
  AddItem(M, 'Level &down', ShortCut(VK_F7, []), @MiLevelDown);
  AddItem(M, 'Level &up', ShortCut(VK_F8, []), @MiLevelUp);
  AddItem(M, '&Restart flight', ShortCut(VK_F9, []), @MiRestart);
  AddItem(M, '-', 0, nil);
  AddItem(M, 'Re&load file (drop changes)', ShortCut(VK_R, [ssCtrl]), @MiReload);

  M := AddItem(FMenu.Items, '&Help', 0, nil);
  AddItem(M, '&Keys and mouse', ShortCut(VK_F1, []), @MiKeys);
end;

procedure TEditorForm.BuildSide;
var
  Tab: TTabSheet;
  TopBar: TPanel;
  I: TGfxImage;
  Box: TScrollBox;
begin
  FSide := TPanel.Create(Self);
  FSide.Parent := Self;
  FSide.Align := alRight;
  FSide.Width := 460;
  FSide.BevelOuter := bvNone;
  FSplit := TSplitter.Create(Self);
  FSplit.Parent := Self;
  FSplit.Align := alRight;
  FSplit.Width := 5;
  FSplit.MinSize := 300;

  FPages := TPageControl.Create(Self);
  FPages.Parent := FSide;
  FPages.Align := alClient;
  FPages.OnChange := @PageChange;

  // ---- Settings
  Tab := FPages.AddTabSheet;
  Tab.Caption := 'Settings';
  TopBar := TPanel.Create(Self);
  TopBar.Parent := Tab;
  TopBar.Align := alTop;
  TopBar.Height := 36;
  TopBar.BevelOuter := bvNone;
  FGroupBox := TComboBox.Create(Self);
  FGroupBox.Parent := TopBar;
  FGroupBox.Style := csDropDownList;
  FGroupBox.DropDownCount := 20;
  FGroupBox.SetBounds(6, 6, 300, 24);
  FGroupBox.Anchors := [akLeft, akTop, akRight];
  FGroupBox.Width := TopBar.Width - 12;
  FGroupBox.OnChange := @GroupChange;
  FHintMemo := TMemo.Create(Self);
  FHintMemo.Parent := Tab;
  FHintMemo.Align := alBottom;
  FHintMemo.Height := 92;
  FHintMemo.ReadOnly := True;
  FHintMemo.WordWrap := True;
  FHintMemo.ScrollBars := ssAutoVertical;
  FHintMemo.Color := clBtnFace;
  FRowBox := TScrollBox.Create(Self);
  FRowBox.Parent := Tab;
  FRowBox.Align := alClient;
  FRowBox.HorzScrollBar.Visible := False;
  FRowBox.VertScrollBar.Increment := RowH;
  FRowBox.BorderStyle := bsNone;
  FRowBox.OnResize := @RowBoxResize;

  // ---- Images
  Tab := FPages.AddTabSheet;
  Tab.Caption := 'Images';
  TopBar := TPanel.Create(Self);
  TopBar.Parent := Tab;
  TopBar.Align := alTop;
  TopBar.Height := 58;
  TopBar.BevelOuter := bvNone;
  FImageBox := TComboBox.Create(Self);
  FImageBox.Parent := TopBar;
  FImageBox.Style := csDropDownList;
  FImageBox.SetBounds(6, 6, 300, 24);
  for I := Low(TGfxImage) to High(TGfxImage) do FImageBox.Items.Add(GfxImageNames[I]);
  FImageBox.ItemIndex := 0;
  FImageBox.OnChange := @ImageChange;
  FImageInfo := TLabel.Create(Self);
  FImageInfo.Parent := TopBar;
  FImageInfo.SetBounds(8, 36, 440, 18);
  Box := TScrollBox.Create(Self);
  Box.Parent := Tab;
  Box.Align := alClient;
  Box.Color := RGBToColor(8, 12, 22);
  FImage := TImage.Create(Self);
  FImage.Parent := Box;
  FImage.Align := alClient;
  FImage.Stretch := True;
  FImage.Proportional := True;
  FImage.Center := True;

  // ---- File
  Tab := FPages.AddTabSheet;
  Tab.Caption := 'File';
  FSummary := TMemo.Create(Self);
  FSummary.Parent := Tab;
  FSummary.Align := alClient;
  FSummary.ReadOnly := True;
  FSummary.ScrollBars := ssAutoBoth;
  FSummary.WordWrap := False;
  FSummary.Font.Name := 'Consolas';
  FSummary.Font.Size := 9;

  FPages.ActivePageIndex := 0;
end;

{ ================================================================== file }

procedure TEditorForm.LoadFile(const FileName: string);
begin
  try
    FData.Load(FileName);
  except
    on E: Exception do
    begin
      MessageDlg(AppName, 'Cannot open ' + FileName + ':' + LineEnding + E.Message, mtError, [mbOK], 0);
      Exit;
    end;
  end;
  FUntitled := False;
  AfterLoad;
end;

// no file: the engine's built-in look; Save asks for a name and writes a complete file
procedure TEditorForm.NewFromDefaults;
begin
  FData.NewEmpty(ExtractFilePath(Application.ExeName) + 'untitled.json');
  FUntitled := True;
  AfterLoad;
end;

procedure TEditorForm.AfterLoad;
begin
  FData.ApplyTo(FHex);
  FCamSpeed := FHex.Settings^.Speed;
  FPendingFx := [];
  BuildRows;
  ResetFlight;
  FSummary.Text := FData.Summary;
  FImagesStale := True;
  if FPages.ActivePageIndex = 1 then ShowImage;
  SetModified(False);
end;

function TEditorForm.DoSave(const FileName: string): boolean;
var
  Old: string;
  Spd: single;
begin
  Result := False;
  Old := FStatus.Panels[0].Text;
  FStatus.Panels[0].Text := 'Saving ' + ExtractFileName(FileName) + ' (baking images) ...';
  FStatus.Update;
  Screen.Cursor := crHourGlass;
  try
    try
      Spd := FHex.Settings^.Speed;
      FHex.Settings^.Speed := FCamSpeed;     // the file keeps its own camera speed
      try
        FData.SaveTo(FileName, FHex);
      finally
        FHex.Settings^.Speed := Spd;
      end;
      Result := True;
    except
      on E: Exception do
      begin
        Screen.Cursor := crDefault;
        MessageDlg(AppName, 'Cannot save ' + FileName + ':' + LineEnding + E.Message, mtError, [mbOK], 0);
      end;
    end;
  finally
    Screen.Cursor := crDefault;
  end;
  FStatus.Panels[0].Text := Old;
  if Result then
  begin
    FUntitled := False;
    FSummary.Text := FData.Summary;
    FImagesStale := True;
    if FPages.ActivePageIndex = 1 then ShowImage;
    SetModified(False);
  end;
end;

function TEditorForm.SaveAs: boolean;
begin
  Result := False;
  FSaveDlg.InitialDir := ExtractFilePath(FData.FileName);
  FSaveDlg.FileName := ExtractFileName(FData.FileName);
  if FSaveDlg.Execute then Result := DoSave(FSaveDlg.FileName);
end;

// True when it is fine to drop the current edits (saved, discarded or none)
function TEditorForm.ConfirmDiscard: boolean;
begin
  Result := True;
  if not FModified then Exit;
  case QuestionDlg(AppName, 'Save the changes to ' + ExtractFileName(FData.FileName) + '?',
    mtWarning, [mrYes, 'Save', mrNo, 'Don''t Save', mrCancel, 'Cancel', 'IsCancel'], 0) of
    mrYes:
      if FUntitled then Result := SaveAs else Result := DoSave(FData.FileName);
    mrNo:
      Result := True;
  else
    Result := False;
  end;
end;

procedure TEditorForm.SetModified(V: boolean);
begin
  FModified := V;
  UpdateCaption;
end;

procedure TEditorForm.UpdateCaption;
var
  S: string;
begin
  S := ExtractFileName(FData.FileName);
  if FModified then S := S + ' *';
  Caption := S + '  -  ' + AppName;
  FStatus.Panels[0].Text := BoolToStr(FModified, 'modified', 'saved') + ':  ' + ExtractFileName(FData.FileName);
end;

procedure TEditorForm.ShowImage;
var
  Img, Disp: TBGRABitmap;
  Which: TGfxImage;
begin
  FImagesStale := False;
  Which := TGfxImage(Max(0, FImageBox.ItemIndex));
  Screen.Cursor := crHourGlass;
  try
    Img := FData.Image(Which);
  finally
    Screen.Cursor := crDefault;
  end;
  if Img = nil then
  begin
    FImage.Picture.Clear;
    FImageInfo.Caption := 'not in this file (Save bakes it)';
    Exit;
  end;
  try
    // straight alpha over the dark blue of the panel
    Disp := TBGRABitmap.Create(Img.Width, Img.Height, BGRA(8, 12, 22));
    try
      Disp.PutImage(0, 0, Img, dmDrawWithTransparency);
      FImage.Picture.Bitmap.SetSize(Disp.Width, Disp.Height);
      Disp.Draw(FImage.Picture.Bitmap.Canvas, 0, 0, True);
    finally
      Disp.Free;
    end;
    case Which of
      giAtlas: FImageInfo.Caption := Format('%d x %d px, %d sprites (kind x size level x blur level)',
          [Img.Width, Img.Height, FData.Root.FindPath('sprites.atlas.entries').Count]);
    else
      FImageInfo.Caption := Format('%d x %d px', [Img.Width, Img.Height]);
    end;
  finally
    Img.Free;
  end;
end;

{ ================================================================== rows }

procedure TEditorForm.BuildRows;
var
  i, n: integer;
  P: TParamInfo;
  Old: string;
begin
  if FGroupBox.ItemIndex >= 0 then Old := FGroupBox.Items[FGroupBox.ItemIndex] else Old := '';
  FRows := nil;
  FGroups.Clear;
  for i := 0 to High(FHex.Params) do
  begin
    P := FHex.Params[i];
    if FGroups.IndexOf(P.Group) < 0 then FGroups.Add(P.Group);
    n := Length(FRows);
    SetLength(FRows, n + 1);
    FRows[n].Group := P.Group;
    FRows[n].Name := P.Name;
    FRows[n].Hint := P.Hint;
    FRows[n].IsColor := P.Kind = pkColor;
    FRows[n].PValue := P.PValue;
    FRows[n].PColor := P.PColor;
    FRows[n].VMin := P.Min;
    FRows[n].VMax := P.Max;
    FRows[n].Decimals := P.Decimals;
    FRows[n].Effects := P.Effects;
    if P.PValue = @FHex.Settings^.Speed then
    begin
      // the autopilot sets the engine's speed from the game rules every frame
      FRows[n].PValue := @FCamSpeed;
      FRows[n].Hint := P.Hint + ' (Stored in the file; the autopilot here flies at the speed of the game rules.)';
    end;
  end;
  AddGameRow('Start speed', 'Speed at level 0, units/s.', @FData.StartSpeed, 1, 60, 2);
  AddGameRow('Max speed', 'Highest speed, units/s.', @FData.MaxSpeed, 1, 120, 2);
  AddGameRow('Speed per gate', 'Speed added per level (gate passed in the game).', @FData.SpeedPerGate, 0, 5, 3);
  AddGameRow('Start gap', 'Gap radius at level 0, units.', @FData.StartGap, 0.5, 10, 2);
  AddGameRow('Min gap', 'Smallest gap radius, units.', @FData.MinGap, 0.3, 10, 2);
  AddGameRow('Gap per gate', 'Gap radius taken away per level.', @FData.GapPerGate, 0, 1, 3);
  AddGameRow('Start spacing', 'Distance between gates at level 0, units.', @FData.StartSpacing, 4, 120, 1);
  AddGameRow('Min spacing', 'Smallest distance between gates, units.', @FData.MinSpacing, 2, 120, 1);
  AddGameRow('Spacing per gate', 'Spacing taken away per level.', @FData.SpacingPerGate, 0, 5, 3);
  AddGameRow('Lateral speed', 'How fast the ship moves sideways, units/s.', @FData.LateralSpeed, 1, 60, 2);
  AddGameRow('Player radius', 'Collision radius of the ship, units.', @FData.PlayerRadius, 0, 3, 2);

  FGroupBox.Items.Assign(FGroups);
  FGroupBox.ItemIndex := Max(0, FGroupBox.Items.IndexOf(Old));
  ShowGroup;
end;

procedure TEditorForm.AddGameRow(const AName, AHint: string; P: PSingle; AMin, AMax: single;
  ADecimals: integer);
var
  n: integer;
begin
  if FGroups.IndexOf(GameGroup) < 0 then FGroups.Add(GameGroup);
  n := Length(FRows);
  SetLength(FRows, n + 1);
  FRows[n].Group := GameGroup;
  FRows[n].Name := AName;
  FRows[n].Hint := AHint + ' Used by the autopilot here and by the game.';
  FRows[n].IsColor := False;
  FRows[n].PValue := P;
  FRows[n].PColor := nil;
  FRows[n].VMin := AMin;
  FRows[n].VMax := AMax;
  FRows[n].Decimals := ADecimals;
  FRows[n].Effects := [];
end;

function TEditorForm.TrackPos(Index: integer): integer;
var
  R: TEdRow;
begin
  R := FRows[Index];
  if R.VMax <= R.VMin then Exit(0);
  Result := Round(EnsureRange((R.PValue^ - R.VMin) / (R.VMax - R.VMin), 0, 1) * TrackSteps);
end;

// one panel per value of the chosen group: name, then slider + number or
// colour button + alpha
procedure TEditorForm.ShowGroup;
var
  i, y, w: integer;
  G: string;
  Row: TPanel;
  L: TLabel;
  T: TTrackBar;
  S: TFloatSpinEdit;
  C: TColorButton;
  A: TSpinEdit;
  First: integer;
begin
  FSyncing := True;
  FRowBox.DisableAutoSizing;
  try
    while FRowBox.ControlCount > 0 do FRowBox.Controls[0].Free;
    if FGroupBox.ItemIndex < 0 then Exit;
    G := FGroupBox.Items[FGroupBox.ItemIndex];
    w := FRowBox.ClientWidth;
    FBuiltW := w;
    y := 0;
    First := -1;
    for i := 0 to High(FRows) do
    begin
      if FRows[i].Group <> G then Continue;
      if First < 0 then First := i;
      Row := TPanel.Create(FRowBox);
      Row.Parent := FRowBox;
      Row.BevelOuter := bvNone;
      Row.SetBounds(0, y, w, RowH);
      Row.Anchors := [akLeft, akTop, akRight];
      Row.Tag := i;
      Row.OnMouseEnter := @RowMouseEnter;
      L := TLabel.Create(Row);
      L.Parent := Row;
      L.Caption := FRows[i].Name;
      L.SetBounds(8, 7, 150, 18);
      L.Tag := i;
      L.OnMouseEnter := @RowMouseEnter;
      if FRows[i].IsColor then
      begin
        C := TColorButton.Create(Row);
        C.Parent := Row;
        C.SetBounds(160, 3, 120, 24);
        C.ButtonColor := ToColor(FRows[i].PColor^);
        C.Tag := i;
        C.OnColorChanged := @ColorChange;
        C.OnMouseEnter := @RowMouseEnter;
        L := TLabel.Create(Row);
        L.Parent := Row;
        L.Caption := 'alpha';
        L.SetBounds(296, 7, 40, 18);
        A := TSpinEdit.Create(Row);
        A.Parent := Row;
        A.SetBounds(338, 3, 72, 24);
        A.MinValue := 0;
        A.MaxValue := 255;
        A.Value := FRows[i].PColor^.alpha;
        A.Tag := i;
        A.OnChange := @AlphaChange;
        A.OnEnter := @RowEnter;
        A.OnMouseEnter := @RowMouseEnter;
      end
      else
      begin
        T := TTrackBar.Create(Row);
        T.Parent := Row;
        T.SetBounds(156, 2, Max(80, w - 156 - 100), 26);
        T.Anchors := [akLeft, akTop, akRight];
        T.Min := 0;
        T.Max := TrackSteps;
        T.TickStyle := tsNone;
        T.LineSize := 1;
        T.PageSize := TrackSteps div 20;
        T.Position := TrackPos(i);
        T.Tag := i;
        T.OnChange := @TrackChange;
        T.OnEnter := @RowEnter;
        T.OnMouseEnter := @RowMouseEnter;
        S := TFloatSpinEdit.Create(Row);
        S.Parent := Row;
        S.SetBounds(w - 94, 3, 86, 24);
        S.Anchors := [akTop, akRight];
        S.DecimalPlaces := FRows[i].Decimals;
        S.Increment := Power(10, -FRows[i].Decimals);
        S.MinValue := FRows[i].VMin;
        S.MaxValue := FRows[i].VMax;
        S.Value := FRows[i].PValue^;
        S.Tag := i;
        S.OnChange := @SpinChange;
        S.OnEnter := @RowEnter;
        S.OnMouseEnter := @RowMouseEnter;
      end;
      Inc(y, RowH);
    end;
    if First >= 0 then ShowRowHint(First);
  finally
    FRowBox.EnableAutoSizing;
    FSyncing := False;
  end;
end;

procedure TEditorForm.ShowRowHint(Index: integer);
var
  R: TEdRow;
  V, Fx: string;
  E: TInvalidate;
begin
  if (Index < 0) or (Index > High(FRows)) then Exit;
  R := FRows[Index];
  if R.IsColor then
    V := Format('[%d, %d, %d, %d]', [R.PColor^.red, R.PColor^.green, R.PColor^.blue, R.PColor^.alpha])
  else
    V := FloatToStrF(R.PValue^, ffFixed, 15, R.Decimals) +
      Format('   range %s .. %s', [FloatToStr(R.VMin), FloatToStr(R.VMax)]);
  Fx := '';
  for E in R.Effects do
    case E of
      ivSprites: Fx := Fx + ' sprites';
      ivScreen: Fx := Fx + ' background/vignette';
      ivField: Fx := Fx + ' hexagon field';
      ivDust: Fx := Fx + ' dust';
      ivSparks: Fx := Fx + ' sparks';
    end;
  if Fx = '' then Fx := ' nothing (live)';
  if R.Group = GameGroup then
    FHintMemo.Text := R.Name + ' = ' + V + LineEnding + R.Hint
  else
    FHintMemo.Text := R.Name + ' = ' + V + LineEnding + R.Hint + LineEnding +
      'File key: settings.' + GfxKey(R.Group, R.Name) + '   rebuilds:' + Fx;
end;

procedure TEditorForm.RowChanged(Index: integer);
begin
  FPendingFx := FPendingFx + FRows[Index].Effects;
  FLastEdit := GetTickCount64;
  if not FModified then SetModified(True);
  ShowRowHint(Index);
end;

procedure TEditorForm.TrackChange(Sender: TObject);
var
  i, k: integer;
  R: TEdRow;
  V: single;
  Row: TWinControl;
begin
  if FSyncing then Exit;
  i := TTrackBar(Sender).Tag;
  R := FRows[i];
  V := R.VMin + (R.VMax - R.VMin) * TTrackBar(Sender).Position / TrackSteps;
  V := RoundTo(V, -R.Decimals);
  if Abs(V - R.PValue^) < 1e-9 then Exit;
  R.PValue^ := V;
  FSyncing := True;
  try
    Row := TTrackBar(Sender).Parent;
    for k := 0 to Row.ControlCount - 1 do
      if Row.Controls[k] is TFloatSpinEdit then TFloatSpinEdit(Row.Controls[k]).Value := V;
  finally
    FSyncing := False;
  end;
  RowChanged(i);
end;

procedure TEditorForm.SpinChange(Sender: TObject);
var
  i, k: integer;
  R: TEdRow;
  V: single;
  Row: TWinControl;
begin
  if FSyncing then Exit;
  i := TFloatSpinEdit(Sender).Tag;
  R := FRows[i];
  V := RoundTo(EnsureRange(TFloatSpinEdit(Sender).Value, R.VMin, R.VMax), -R.Decimals);
  if Abs(V - R.PValue^) < 1e-9 then Exit;
  R.PValue^ := V;
  FSyncing := True;
  try
    Row := TFloatSpinEdit(Sender).Parent;
    for k := 0 to Row.ControlCount - 1 do
      if Row.Controls[k] is TTrackBar then TTrackBar(Row.Controls[k]).Position := TrackPos(i);
  finally
    FSyncing := False;
  end;
  RowChanged(i);
end;

procedure TEditorForm.ColorChange(Sender: TObject);
var
  i: integer;
  c: TColor;
begin
  if FSyncing then Exit;
  i := TColorButton(Sender).Tag;
  c := ColorToRGB(TColorButton(Sender).ButtonColor);
  if (FRows[i].PColor^.red = Red(c)) and (FRows[i].PColor^.green = Green(c)) and
    (FRows[i].PColor^.blue = Blue(c)) then Exit;
  FRows[i].PColor^.red := Red(c);
  FRows[i].PColor^.green := Green(c);
  FRows[i].PColor^.blue := Blue(c);
  RowChanged(i);
end;

procedure TEditorForm.AlphaChange(Sender: TObject);
var
  i: integer;
begin
  if FSyncing then Exit;
  i := TSpinEdit(Sender).Tag;
  if FRows[i].PColor^.alpha = EnsureRange(TSpinEdit(Sender).Value, 0, 255) then Exit;
  FRows[i].PColor^.alpha := EnsureRange(TSpinEdit(Sender).Value, 0, 255);
  RowChanged(i);
end;

// rows are laid out for the panel width they were made at: make them again
// when the width really changes (first show, window or splitter resize)
procedure TEditorForm.RowBoxResize(Sender: TObject);
begin
  if not FSyncing and (Abs(FRowBox.ClientWidth - FBuiltW) > 2) then ShowGroup;
end;

procedure TEditorForm.RowEnter(Sender: TObject);
begin
  ShowRowHint(TControl(Sender).Tag);
end;

procedure TEditorForm.RowMouseEnter(Sender: TObject);
begin
  ShowRowHint(TControl(Sender).Tag);
end;

procedure TEditorForm.GroupChange(Sender: TObject);
begin
  ShowGroup;
end;

procedure TEditorForm.ImageChange(Sender: TObject);
begin
  ShowImage;
end;

procedure TEditorForm.PageChange(Sender: TObject);
begin
  if (FPages.ActivePageIndex = 1) and FImagesStale then ShowImage;
end;

{ ================================================================= menus }

procedure TEditorForm.MiOpen(Sender: TObject);
begin
  if not ConfirmDiscard then Exit;
  FOpenDlg.InitialDir := ExtractFilePath(FData.FileName);
  FOpenDlg.FileName := '';
  if FOpenDlg.Execute then LoadFile(FOpenDlg.FileName);
end;

procedure TEditorForm.MiSave(Sender: TObject);
begin
  if FUntitled then SaveAs else DoSave(FData.FileName);
end;

procedure TEditorForm.MiSaveAs(Sender: TObject);
begin
  SaveAs;
end;

procedure TEditorForm.MiExit(Sender: TObject);
begin
  Close;                             // FormCloseQuery asks about unsaved changes
end;

procedure TEditorForm.MiPanel(Sender: TObject);
begin
  FMiPanel.Checked := not FMiPanel.Checked;
  FSide.Visible := FMiPanel.Checked;
  FSplit.Visible := FMiPanel.Checked;
  if FSplit.Visible then FSplit.Left := FSide.Left - FSplit.Width;
end;

procedure TEditorForm.MiFullScreen(Sender: TObject);
begin
  FFullScreen := not FFullScreen;
  if FFullScreen then
  begin
    FSavedBounds := BoundsRect;
    BorderStyle := bsNone;
    BoundsRect := Monitor.BoundsRect;
  end
  else
  begin
    BorderStyle := bsSizeable;
    BoundsRect := FSavedBounds;
  end;
end;

procedure TEditorForm.MiPng(Sender: TObject);
var
  Bmp: TBGRABitmap;
  PngName: string;
begin
  Bmp := TBGRABitmap.Create(1, 1);
  try
    FHex.AsyncSprites := False;      // exact sprites for the saved picture
    try
      FHex.Render(Bmp, FOutput.Width, FOutput.Height, [0..PassCount - 1], False, False);
    finally
      FHex.AsyncSprites := True;
    end;
    PngName := ChangeFileExt(FData.FileName, '') + FormatDateTime('"_"yyyymmdd"_"hhnnss', Now) + '.png';
    Bmp.SaveToFile(PngName);
    FStatus.Panels[3].Text := 'saved ' + ExtractFileName(PngName);
  finally
    Bmp.Free;
  end;
end;

procedure TEditorForm.MiPause(Sender: TObject);
begin
  FPaused := not FPaused;
  FMiPause.Checked := FPaused;
end;

procedure TEditorForm.MiGates(Sender: TObject);
begin
  FGatesOn := not FGatesOn;
  FMiGates.Checked := FGatesOn;
  ResetFlight;
end;

procedure TEditorForm.MiLevelUp(Sender: TObject);
begin
  FLevel := Min(MaxLevel, FLevel + 5);
end;

procedure TEditorForm.MiLevelDown(Sender: TObject);
begin
  FLevel := Max(0, FLevel - 5);
end;

procedure TEditorForm.MiRestart(Sender: TObject);
begin
  FPassed := 0;
  FHits := 0;
  ResetFlight;
end;

procedure TEditorForm.MiReload(Sender: TObject);
begin
  if FUntitled then Exit;
  if FModified and (MessageDlg(AppName, 'Drop all changes and reload ' + ExtractFileName(FData.FileName) + '?',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes) then Exit;
  LoadFile(FData.FileName);
end;

procedure TEditorForm.MiKeys(Sender: TObject);
begin
  MessageDlg(AppName,
    'File:  Ctrl+O open,  Ctrl+S save,  Ctrl+Shift+S save as,  Alt+F4 exit,  Ctrl+R reload' + LineEnding +
    'View:  F4 edit panel,  F11 full screen,  F12 save the picture as PNG' + LineEnding +
    'Simulation:  F5 pause,  F6 gates on/off,  F7 / F8 level down / up,  F9 restart' + LineEnding +
    'Mouse:  hold the left button on the picture to steer (else the autopilot flies)' + LineEnding + LineEnding +
    'Settings page: pick a group, drag a slider or type a number; colours open the colour' + LineEnding +
    'dialog. The picture follows at once. Save writes the values and re-bakes all images' + LineEnding +
    'of the file (atlas, background, vignette, reference frame).',
    mtInformation, [mbOK], 0);
end;

{ ================================================================ frames }

procedure TEditorForm.AppIdle(Sender: TObject; var Done: boolean);
var
  Now: double;
begin
  Done := False;                     // keep the idle loop running
  if not Visible or (WindowState = wsMinimized) then
  begin
    Sleep(5);
    Exit;
  end;
  if FUseGL then
  begin
    DoFrame;                         // SwapBuffers waits for the vertical blank
    Exit;
  end;
  Now := NowMs;
  if Now < FLastTick + 1000 / FallbackFps then
  begin
    Sleep(1);
    Exit;
  end;
  DoFrame;
end;

procedure TEditorForm.DoFrame;
var
  t, dt: double;
  W, H: integer;
begin
  t := NowMs;
  dt := Min(0.1, (t - FLastTick) / 1000);
  FLastTick := t;
  // caches are rebuilt once the user stops changing a value
  if (FPendingFx <> []) and (GetTickCount64 - FLastEdit > 150) then
  begin
    FHex.Invalidate(FPendingFx);
    FPendingFx := [];
  end;
  Fly(dt);
  W := Max(16, Round(FOutput.Width * EnsureRange(FHex.Settings^.RenderScale, 0.1, 2)));
  H := Max(16, Round(FOutput.Height * EnsureRange(FHex.Settings^.RenderScale, 0.1, 2)));
  FHex.Render(FFrame, W, H, [0..PassCount - 1], False, True);
  Present;

  Inc(FFrames);
  if t - FFpsStart >= 500 then
  begin
    FFps := FFrames * 1000 / (t - FFpsStart);
    FFrames := 0;
    FFpsStart := t;
    FStatus.Panels[1].Text := Format('%.0f fps   %dx%d   list %.1f  draw %.1f ms   %s',
      [FFps, W, H, FHex.Stats.SetupMs, FHex.Stats.DrawMs, BoolToStr(FUseGL, 'OpenGL vsync', 'GDI')]);
    FStatus.Panels[2].Text := Format('level %d   speed %.1f   gates %s   passed %d   hit %d   %s',
      [FLevel, FSpeed, BoolToStr(FGatesOn, 'on', 'off'), FPassed, FHits,
       BoolToStr(FSteering, 'mouse', BoolToStr(FPaused, 'paused', 'autopilot'))]);
    FStatus.Panels[3].Text := Format('settings %d / %d from the file   seed %d',
      [FData.SettingsApplied, FData.SettingsTotal, FHex.Seed]);
  end;
end;

procedure TEditorForm.Present;
begin
  if FUseGL then
    try
      PresentGL;
    except
      UseGDI;
    end
  else
    FView.Repaint;
end;

procedure TEditorForm.UseGDI;
begin
  FUseGL := False;
  if FGL <> nil then FGL.Visible := False;
  FView.Visible := True;
  FOutput := FView;
end;

// Upload the frame as a texture and draw it as one quad; SwapBuffers then
// waits for the vertical blank (the same output as HexGate).
procedure TEditorForm.PresentGL;
type
  TSwapInterval = function(Interval: longint): LongBool; stdcall;
const
  GL_BGRA = $80E1;
  GL_CLAMP_TO_EDGE = $812F;
var
  SwapInterval: TSwapInterval;
  v0, v1: single;
begin
  if not FGL.MakeCurrent then
    raise Exception.Create('cannot make the OpenGL context current');
  if not FGLReady then
  begin
    glGenTextures(1, @FTexture);
    glBindTexture(GL_TEXTURE_2D, FTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    FTexW := 0;
    FGLReady := True;
  end;
  if not FVSyncSet then
  begin
    {$IFDEF WINDOWS}
    Pointer(SwapInterval) := wglGetProcAddress('wglSwapIntervalEXT');
    if Assigned(SwapInterval) then SwapInterval(1);
    {$ENDIF}
    FVSyncSet := True;
  end;

  glViewport(0, 0, FGL.Width, FGL.Height);
  glBindTexture(GL_TEXTURE_2D, FTexture);
  if (FTexW <> FFrame.Width) or (FTexH <> FFrame.Height) then
  begin
    FTexW := FFrame.Width;
    FTexH := FFrame.Height;
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, FTexW, FTexH, 0, GL_BGRA, GL_UNSIGNED_BYTE, FFrame.Data);
  end
  else
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, FTexW, FTexH, GL_BGRA, GL_UNSIGNED_BYTE, FFrame.Data);
  if FFrame.LineOrder = riloBottomToTop then
  begin
    v0 := 0;
    v1 := 1;
  end
  else
  begin
    v0 := 1;
    v1 := 0;
  end;
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity;
  glMatrixMode(GL_MODELVIEW);
  glLoadIdentity;
  glDisable(GL_BLEND);
  glDisable(GL_DEPTH_TEST);
  glEnable(GL_TEXTURE_2D);
  glColor4f(1, 1, 1, 1);
  glBegin(GL_QUADS);
    glTexCoord2f(0, v0); glVertex2f(-1, -1);
    glTexCoord2f(1, v0); glVertex2f(1, -1);
    glTexCoord2f(1, v1); glVertex2f(1, 1);
    glTexCoord2f(0, v1); glVertex2f(-1, 1);
  glEnd;
  FGL.SwapBuffers;
  glFinish;
end;

procedure TEditorForm.GLPaint(Sender: TObject);
begin
  if FUseGL and (FFrame.Width > 16) then
    try
      PresentGL;
    except
      UseGDI;
    end;
end;

procedure TEditorForm.ViewPaint(Sender: TObject);
begin
  FFrame.Draw(FView.Canvas, Rect(0, 0, FView.Width, FView.Height), True);
end;

procedure TEditorForm.OutputMouseMove(Sender: TObject; Shift: TShiftState; X, Y: integer);
begin
  if (FOutput.Width > 0) and (FOutput.Height > 0) then
  begin
    FMouseX := EnsureRange(X / FOutput.Width * 2 - 1, -1, 1);
    FMouseY := EnsureRange(Y / FOutput.Height * 2 - 1, -1, 1);
  end;
end;

procedure TEditorForm.OutputMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: integer);
begin
  if Button = mbLeft then
  begin
    OutputMouseMove(Sender, Shift, X, Y);
    FSteering := True;
  end;
end;

procedure TEditorForm.OutputMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: integer);
begin
  if Button = mbLeft then FSteering := False;
end;

{ ============================================================= autopilot }

procedure TEditorForm.ResetFlight;
begin
  FGates := nil;
  FHex.ClearGates;
  FLastGateZ := FHex.CameraPos.Z + 20;
  FLastGX := FPX;
  FLastGY := FPY;
  FSpeed := FData.StartSpeed;
end;

// gates follow the file's game rules (game.rules) at the chosen level
procedure TEditorForm.SpawnGates;
var
  spacing, gr, spd, maxShift, lim, a, rr, gx, gy, d: single;
  Tries, i: integer;
begin
  lim := FHex.Settings^.CorridorRadius - 1.5;
  while FLastGateZ < FHex.CameraPos.Z + FHex.Settings^.FarClip + 6 do
  begin
    spacing := Max(FData.MinSpacing, FData.StartSpacing - FData.SpacingPerGate * FLevel);
    gr := Max(FData.MinGap, FData.StartGap - FData.GapPerGate * FLevel);
    spd := Max(0.5, Min(FData.MaxSpeed, FData.StartSpeed + FData.SpeedPerGate * FLevel));
    maxShift := FData.LateralSpeed * spacing / spd * 0.7;
    Tries := 0;
    repeat
      a := Random * 2 * Pi;
      rr := Sqrt(Random) * Max(0, lim);
      gx := rr * Cos(a);
      gy := rr * Sin(a);
      d := Sqrt(Sqr(gx - FLastGX) + Sqr(gy - FLastGY));
      Inc(Tries);
    until (d <= maxShift) or (Tries > 30);
    if (d > maxShift) and (d > 0) then
    begin
      gx := FLastGX + (gx - FLastGX) * maxShift / d;
      gy := FLastGY + (gy - FLastGY) * maxShift / d;
    end;
    FLastGateZ := FLastGateZ + Max(1, spacing);
    FLastGX := gx;
    FLastGY := gy;
    i := Length(FGates);
    SetLength(FGates, i + 1);
    FGates[i].Z := FLastGateZ;
    FGates[i].GX := gx;
    FGates[i].GY := gy;
    FGates[i].GR := gr;
    FHex.AddGate(FLastGateZ, gx, gy, gr);
  end;
end;

procedure TEditorForm.Fly(dt: single);
var
  ox, oy, tx, ty, lim, l, step, z0, z1: single;
  i, g: integer;
begin
  if FPaused then
  begin
    FHex.Animate(0);
    Exit;
  end;
  lim := Max(0, FHex.Settings^.CorridorRadius - 1.5);
  g := -1;
  for i := 0 to High(FGates) do
    if FGates[i].Z > FHex.CameraPos.Z then
    begin
      g := i;
      Break;
    end;
  if FSteering then
  begin
    tx := FMouseX * lim;
    ty := FMouseY * lim;
  end
  else if g >= 0 then
  begin
    tx := FGates[g].GX;
    ty := FGates[g].GY;
  end
  else
  begin
    tx := 0;
    ty := 0;
  end;
  ox := FPX;
  oy := FPY;
  l := Sqrt(Sqr(tx - FPX) + Sqr(ty - FPY));
  step := FData.LateralSpeed * dt;
  if l <= step then
  begin
    FPX := tx;
    FPY := ty;
  end
  else
  begin
    FPX := FPX + (tx - FPX) / l * step;
    FPY := FPY + (ty - FPY) / l * step;
  end;
  l := Sqrt(FPX * FPX + FPY * FPY);
  if (l > lim) and (l > 0) then
  begin
    FPX := FPX * lim / l;
    FPY := FPY * lim / l;
  end;
  if dt > 0 then
  begin
    FVX := FVX + ((FPX - ox) / dt - FVX) * Min(1, dt * 8);
    FVY := FVY + ((FPY - oy) / dt - FVY) * Min(1, dt * 8);
  end;

  FSpeed := FSpeed + (Min(FData.MaxSpeed, FData.StartSpeed + FData.SpeedPerGate * FLevel) - FSpeed) * Min(1, dt * 2);
  FHex.Settings^.Speed := FSpeed;
  if FGatesOn then SpawnGates;

  z0 := FHex.CameraPos.Z;
  z1 := z0 + FSpeed * dt;
  for i := 0 to High(FGates) do
    if (FGates[i].Z > z0) and (FGates[i].Z <= z1) then
      if Sqrt(Sqr(FPX - FGates[i].GX) + Sqr(FPY - FGates[i].GY)) <= FGates[i].GR - FData.PlayerRadius then
        Inc(FPassed)
      else
        Inc(FHits);
  while (Length(FGates) > 0) and (FGates[0].Z < z0 - 2) do
    Delete(FGates, 0, 1);

  // the camera is the ship (game.rules)
  FHex.SetManualCamera(FPX, FPY, FVX * 0.012, -FVY * 0.008, -FVX * 0.02);
  if g >= 0 then FHex.FocusOverride := Max(2, FGates[g].Z - z0) else FHex.FocusOverride := 12;
  FHex.Animate(dt);
end;

end.
