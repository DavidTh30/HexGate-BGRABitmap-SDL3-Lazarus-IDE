unit UMain;

{ Window: the camera fly-through on the left, inspector panel on the right.
  Move the mouse over the picture to steer the camera.

  Inspector tabs
    Passes     - the 8 render passes with live thumbnail, on/off box, items
                 drawn and time per frame. Click a row to view it alone.
    Parameters - every value of THexSettings, generated from Hex.Params.
                 Camera / lens / fog values apply on the next frame; values
                 that feed a cache (sprites, field, particles) rebuild it
                 when the slider stops.
    Info       - live report: camera, lens, world, sprite cache, passes and
                 all parameter values.

  Output
    Frames are shown through OpenGL: the finished frame is uploaded as a
    BGRA texture and drawn as one quad (the GPU stretches it to the window),
    and SwapBuffers with swap interval 1 waits for the vertical blank, so
    there is no tearing and the display paces the animation. If OpenGL
    cannot start, or VSync is off, frames are painted with GDI on a 60 Hz
    timer grid instead.

  Keys (when no edit box has focus): R new seed, S save PNG, Space pause,
  F2 show/hide panel, F11 fullscreen, Esc leave fullscreen / unfocus. }

{$mode objfpc}{$H+}

interface

uses
  {$IFDEF WINDOWS}Windows, MMSystem,{$ENDIF}
  Classes, SysUtils, Math, Forms, Controls, Graphics, GraphType, ExtCtrls, StdCtrls, ComCtrls,
  Spin, Dialogs, Clipbrd, LCLType, GL, OpenGLContext, BGRABitmap, BGRABitmapTypes, UHexBackground;

type
  TPassRow = record
    Panel: TPanel;
    Check: TCheckBox;
    Thumb: TImage;
    Title, Stats: TLabel;
  end;

  TParamRow = record
    Track: TTrackBar;
    Spin: TFloatSpinEdit;
    ColorBtn: TColorButton;
    Alpha: TSpinEdit;
  end;

  { TMainForm }

  TMainForm = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
  private
    FHex: THexBackground;
    FFrame: TBGRABitmap;
    FView: TPaintBox;                // GDI fallback output
    FGL: TOpenGLControl;             // OpenGL output (vsync)
    FOutput: TControl;               // whichever of the two is in use
    FUseGL, FGLReady, FVSync, FVSyncApplied, FVSyncSupported: boolean;
    FTexture: GLuint;
    FTexW, FTexH: integer;
    FVSyncCheck: TCheckBox;
    FWaitMs: double;
    FRefreshHz: integer;
    FSide: TPanel;
    FSplitter: TSplitter;
    FPages: TPageControl;
    FPassTab, FInfoTab: TTabSheet;
    FViewCombo: TComboBox;
    FSeedEdit: TSpinEdit;
    FPauseBtn: TButton;
    FStatus: TLabel;
    FInfoMemo: TMemo;
    FPassRows: array[0..PassCount - 1] of TPassRow;
    FParamRows: array of TParamRow;
    FUpdating, FPaused, FFullScreen: boolean;
    FPending: TInvalidateSet;
    FPendingAt, FLastThumbs, FLastInfo: QWord;
    FLastStatus: double;
    FThumbNext, FRowNext, FDropped, FDroppedTotal: integer;
    FInfoAuto: TCheckBox;
    FLastTick, FNextFrame, FShowMs: double;
    FFrames: integer;
    FFps: double;
    FSavedBounds: TRect;
    procedure BuildSidePanel;
    procedure BuildPassesTab(Tab: TTabSheet);
    procedure BuildParamsTab(Tab: TTabSheet);
    procedure BuildInfoTab(Tab: TTabSheet);
    function AddButton(AParent: TWinControl; const ACaption: string;
      X, Y, W: integer; AOnClick: TNotifyEvent): TButton;
    function AddLabel(AParent: TWinControl; const ACaption: string; X, Y: integer): TLabel;
    function CompositePasses: TPassSet;
    procedure RefreshPassRows(WithThumbs: boolean);
    procedure RefreshThumb(i: integer);
    procedure RefreshPassRow(i: integer);
    procedure RefreshInfo;
    procedure InfoRefreshClick(Sender: TObject);
    procedure RefreshParamControls;
    procedure RenderFrame;
    procedure ToggleFullScreen;
    procedure AppIdle(Sender: TObject; var Done: boolean);
    procedure Present;
    procedure PresentGL;
    procedure UseGDI(const Reason: string);
    procedure GLPaint(Sender: TObject);
    procedure VSyncClick(Sender: TObject);
    procedure DoFrame;
    procedure ViewPaint(Sender: TObject);
    procedure ViewMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: integer);
    procedure ViewMouseMove(Sender: TObject; Shift: TShiftState; X, Y: integer);
    procedure ViewMouseLeave(Sender: TObject);
    procedure PassCheckClick(Sender: TObject);
    procedure PassRowClick(Sender: TObject);
    procedure ViewComboChange(Sender: TObject);
    procedure TrackChange(Sender: TObject);
    procedure SpinChange(Sender: TObject);
    procedure ColorChanged(Sender: TObject);
    procedure SeedChange(Sender: TObject);
    procedure NewSeedClick(Sender: TObject);
    procedure ResetClick(Sender: TObject);
    procedure PauseClick(Sender: TObject);
    procedure SavePngClick(Sender: TObject);
    procedure SaveIniClick(Sender: TObject);
    procedure LoadIniClick(Sender: TObject);
    procedure CopyInfoClick(Sender: TObject);
    procedure ParamChanged(Index: integer);
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

const
  SideWidth = 450;
  RowH = 26;
  MaxFps = 60;
  ThumbW = 120;
  ThumbH = 68;

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
{$IFDEF WINDOWS}
var
  ScreenDC: HDC;
{$ENDIF}
begin
  Caption := 'Hex Background - camera fly-through   (mouse steers, R new seed, S save PNG, Space pause, F2 panel, F11 fullscreen)';
  ShowHint := True;
  FHex := THexBackground.Create;
  FHex.AsyncSprites := True;           // live view: big sprites are built in the background
  FFrame := TBGRABitmap.Create(16, 16, BGRABlack);

  FSide := TPanel.Create(Self);
  FSide.Parent := Self;
  FSide.Align := alRight;
  FSide.Width := SideWidth;
  FSide.BevelOuter := bvNone;
  FSide.ParentColor := False;
  FSide.Color := clBtnFace;

  FSplitter := TSplitter.Create(Self);
  FSplitter.Parent := Self;
  FSplitter.Align := alRight;
  FSplitter.Width := 5;

  FView := TPaintBox.Create(Self);
  FView.Parent := Self;
  FView.Align := alClient;
  FView.Visible := False;
  FView.OnPaint := @ViewPaint;
  FView.OnMouseDown := @ViewMouseDown;
  FView.OnMouseMove := @ViewMouseMove;
  FView.OnMouseLeave := @ViewMouseLeave;

  FVSync := True;
  FUseGL := True;
  try
    FGL := TOpenGLControl.Create(Self);
    FGL.Parent := Self;
    FGL.Align := alClient;
    FGL.AutoResizeViewport := False;
    FGL.DepthBits := 0;
    FGL.OnPaint := @GLPaint;
    FGL.OnMouseDown := @ViewMouseDown;
    FGL.OnMouseMove := @ViewMouseMove;
    FGL.OnMouseLeave := @ViewMouseLeave;
    FOutput := FGL;
  except
    on E: Exception do UseGDI(E.Message);
  end;
  {$IFDEF WINDOWS}
  ScreenDC := GetDC(0);
  FRefreshHz := GetDeviceCaps(ScreenDC, VREFRESH);
  ReleaseDC(0, ScreenDC);
  {$ENDIF}

  BuildSidePanel;

  // frames run from the idle loop (up to MaxFps) instead of a 15 ms timer:
  // steadier frame pacing, and dt comes from the high-resolution clock
  FLastTick := NowMs;
  FNextFrame := FLastTick;
  {$IFDEF WINDOWS}
  timeBeginPeriod(1);                // Sleep(1) really sleeps ~1 ms, not ~15 ms
  {$ENDIF}
  Application.AddOnIdleHandler(@AppIdle);
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  Application.RemoveOnIdleHandler(@AppIdle);
  {$IFDEF WINDOWS}
  timeEndPeriod(1);
  {$ENDIF}
  FFrame.Free;
  FHex.Free;
end;

{ ------------------------------------------------------------ side panel }

function TMainForm.AddButton(AParent: TWinControl; const ACaption: string;
  X, Y, W: integer; AOnClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := AParent;
  Result.SetBounds(X, Y, W, 25);
  Result.Caption := ACaption;
  Result.OnClick := AOnClick;
end;

function TMainForm.AddLabel(AParent: TWinControl; const ACaption: string; X, Y: integer): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := AParent;
  Result.Left := X;
  Result.Top := Y;
  Result.Caption := ACaption;
end;

procedure TMainForm.BuildSidePanel;
var
  TopBar: TPanel;
  i: integer;
  Tab: TTabSheet;
begin
  TopBar := TPanel.Create(Self);
  TopBar.Parent := FSide;
  TopBar.Align := alTop;
  TopBar.Height := 104;
  TopBar.BevelOuter := bvNone;

  AddLabel(TopBar, 'View:', 8, 12);
  FViewCombo := TComboBox.Create(Self);
  FViewCombo.Parent := TopBar;
  FViewCombo.SetBounds(52, 8, 200, 23);
  FViewCombo.Style := csDropDownList;
  FViewCombo.Items.Add('Composite (final image)');
  for i := 0 to PassCount - 1 do
    FViewCombo.Items.Add(Format('%d  %s (alone)', [i, FHex.Passes[i]^.Name]));
  FViewCombo.ItemIndex := 0;
  FViewCombo.OnChange := @ViewComboChange;
  FViewCombo.Hint := 'Show the final image, or one pass alone over a checkerboard.';
  FPauseBtn := AddButton(TopBar, 'Pause', 260, 7, 80, @PauseClick);
  FPauseBtn.Hint := 'Freeze the camera and particles (Space).';
  FVSyncCheck := TCheckBox.Create(Self);
  FVSyncCheck.Parent := TopBar;
  FVSyncCheck.SetBounds(350, 10, 90, 20);
  FVSyncCheck.Caption := 'VSync';
  FVSyncCheck.Checked := FVSync;
  FVSyncCheck.Enabled := FUseGL;
  FVSyncCheck.OnClick := @VSyncClick;
  FVSyncCheck.Hint := 'OpenGL output waits for the monitor''s vertical blank: no tearing, ' +
    'the display paces the frames.'#13'Off: frames are shown as soon as they are ready (60 fps cap).';

  AddLabel(TopBar, 'Seed:', 8, 42);
  FSeedEdit := TSpinEdit.Create(Self);
  FSeedEdit.Parent := TopBar;
  FSeedEdit.SetBounds(52, 38, 110, 23);
  FSeedEdit.MaxValue := MaxInt;
  FSeedEdit.Value := FHex.Seed;
  FSeedEdit.OnChange := @SeedChange;
  FSeedEdit.Hint := 'Random seed of the hexagon field and particles.';
  AddButton(TopBar, 'New seed', 170, 37, 82, @NewSeedClick);
  AddButton(TopBar, 'Reset all', 260, 37, 80, @ResetClick).Hint := 'Restore every parameter to its default.';

  AddButton(TopBar, 'Save PNG', 8, 70, 90, @SavePngClick).Hint :=
    'Save the current frame at full window resolution.';
  AddButton(TopBar, 'Save settings...', 104, 70, 112, @SaveIniClick);
  AddButton(TopBar, 'Load settings...', 222, 70, 118, @LoadIniClick);

  FStatus := TLabel.Create(Self);
  FStatus.Parent := FSide;
  FStatus.Align := alBottom;
  FStatus.BorderSpacing.Around := 6;
  FStatus.AutoSize := False;          // a new text must not re-layout the panel
  FStatus.Height := 50;
  FStatus.WordWrap := True;
  FStatus.Caption := '';

  FPages := TPageControl.Create(Self);
  FPages.Parent := FSide;
  FPages.Align := alClient;
  FPassTab := FPages.AddTabSheet;
  BuildPassesTab(FPassTab);
  Tab := FPages.AddTabSheet;
  BuildParamsTab(Tab);
  FInfoTab := FPages.AddTabSheet;
  BuildInfoTab(FInfoTab);
  FPages.ActivePageIndex := 0;
end;

procedure TMainForm.BuildPassesTab(Tab: TTabSheet);
var
  Box: TScrollBox;
  i: integer;
  P: TPanel;
begin
  Tab.Caption := 'Passes';
  Box := TScrollBox.Create(Self);
  Box.Parent := Tab;
  Box.Align := alClient;
  Box.HorzScrollBar.Visible := False;
  Box.VertScrollBar.Tracking := True;

  // top of the list = drawn last (on top)
  for i := PassCount - 1 downto 0 do
  begin
    P := TPanel.Create(Self);
    P.Parent := Box;
    P.Top := (PassCount - i) * 1000;
    P.Align := alTop;
    P.Height := ThumbH + 10;
    P.BevelOuter := bvNone;
    P.BorderSpacing.Bottom := 1;
    P.Tag := i;
    P.OnClick := @PassRowClick;
    P.Cursor := crHandPoint;
    FPassRows[i].Panel := P;

    with FPassRows[i] do
    begin
      Check := TCheckBox.Create(Self);
      Check.Parent := P;
      Check.SetBounds(6, (ThumbH + 10 - 20) div 2, 20, 20);
      Check.Checked := FHex.Passes[i]^.Enabled;
      Check.Tag := i;
      Check.OnClick := @PassCheckClick;
      Check.Hint := 'Include this pass in the final image.';

      Thumb := TImage.Create(Self);
      Thumb.Parent := P;
      Thumb.SetBounds(28, 5, ThumbW, ThumbH);
      Thumb.Tag := i;
      Thumb.OnClick := @PassRowClick;

      Title := TLabel.Create(Self);
      Title.Parent := P;
      Title.Left := ThumbW + 36;
      Title.Top := 4;
      Title.Font.Style := [fsBold];
      Title.Caption := Format('%d. %s', [i, FHex.Passes[i]^.Name]);
      Title.Tag := i;
      Title.OnClick := @PassRowClick;

      Stats := TLabel.Create(Self);
      Stats.Parent := P;
      Stats.AutoSize := False;
      Stats.WordWrap := True;
      Stats.SetBounds(ThumbW + 36, 22, SideWidth - ThumbW - 70, ThumbH - 16);
      Stats.Tag := i;
      Stats.OnClick := @PassRowClick;
      Stats.Hint := FHex.Passes[i]^.Technique;
      Thumb.Hint := 'Click to view alone.'#13 + FHex.Passes[i]^.Technique;
    end;
  end;
end;

procedure TMainForm.BuildParamsTab(Tab: TTabSheet);
var
  Box: TScrollBox;
  GB: TGroupBox;
  i, k, n, GroupNo, Y: integer;
  P: TParamInfo;
  L: TLabel;
  Live: string;
begin
  Tab.Caption := 'Parameters';
  Box := TScrollBox.Create(Self);
  Box.Parent := Tab;
  Box.Align := alClient;
  Box.HorzScrollBar.Visible := False;
  Box.VertScrollBar.Tracking := True;
  Box.VertScrollBar.Increment := RowH;

  SetLength(FParamRows, Length(FHex.Params));
  i := 0;
  GroupNo := 0;
  while i <= High(FHex.Params) do
  begin
    n := 0;
    while (i + n <= High(FHex.Params)) and (FHex.Params[i + n].Group = FHex.Params[i].Group) do
      Inc(n);

    GB := TGroupBox.Create(Self);
    GB.Parent := Box;
    GB.Top := (GroupNo + 1) * 10000;
    GB.Align := alTop;
    GB.BorderSpacing.Around := 4;
    GB.Caption := ' ' + FHex.Params[i].Group + ' ';
    GB.Height := n * RowH + 26;
    Inc(GroupNo);

    for k := 0 to n - 1 do
    begin
      P := FHex.Params[i + k];
      Y := 2 + k * RowH;
      if P.Effects = [] then Live := #13'Applies on the next frame.'
      else Live := #13'Rebuilds a cache when you stop changing it.';

      L := AddLabel(GB, P.Name, 8, Y + 4);
      L.Hint := P.Hint + Live;

      if P.Kind = pkFloat then
      begin
        FParamRows[i + k].Track := TTrackBar.Create(Self);
        with FParamRows[i + k].Track do
        begin
          Parent := GB;
          SetBounds(140, Y, 180, 24);
          Min := 0;
          Max := 1000;
          TickStyle := tsNone;
          PageSize := 50;
          Tag := i + k;
          Hint := P.Hint + Live;
          OnChange := @TrackChange;
        end;
        FParamRows[i + k].Spin := TFloatSpinEdit.Create(Self);
        with FParamRows[i + k].Spin do
        begin
          Parent := GB;
          SetBounds(326, Y, 84, 23);
          DecimalPlaces := P.Decimals;
          MinValue := P.Min;
          MaxValue := P.Max;
          Increment := Power(10, -P.Decimals);
          Tag := i + k;
          Hint := Format('%s'#13'Range %g .. %g', [P.Hint, P.Min, P.Max]) + Live;
          OnChange := @SpinChange;
        end;
      end
      else
      begin
        FParamRows[i + k].ColorBtn := TColorButton.Create(Self);
        with FParamRows[i + k].ColorBtn do
        begin
          Parent := GB;
          SetBounds(140, Y, 120, 24);
          Tag := i + k;
          Hint := P.Hint + Live;
          OnColorChanged := @ColorChanged;
        end;
        AddLabel(GB, 'alpha', 286, Y + 4);
        FParamRows[i + k].Alpha := TSpinEdit.Create(Self);
        with FParamRows[i + k].Alpha do
        begin
          Parent := GB;
          SetBounds(326, Y, 84, 23);
          MinValue := 0;
          MaxValue := 255;
          Tag := i + k;
          Hint := 'Alpha 0..255 of this colour.';
          OnChange := @ColorChanged;
        end;
      end;
    end;
    Inc(i, n);
  end;
  RefreshParamControls;
end;

procedure TMainForm.BuildInfoTab(Tab: TTabSheet);
var
  Bar: TPanel;
begin
  Tab.Caption := 'Info';
  Bar := TPanel.Create(Self);
  Bar.Parent := Tab;
  Bar.Align := alBottom;
  Bar.Height := 34;
  Bar.BevelOuter := bvNone;
  AddButton(Bar, 'Copy report', 6, 4, 110, @CopyInfoClick);
  AddButton(Bar, 'Refresh', 122, 4, 80, @InfoRefreshClick);
  FInfoAuto := TCheckBox.Create(Self);
  FInfoAuto.Parent := Bar;
  FInfoAuto.SetBounds(212, 7, 200, 20);
  FInfoAuto.Caption := 'Auto refresh every 2 s';
  FInfoAuto.Hint := 'Rewriting the long report takes several ms on the UI thread and can ' +
    'make a frame miss a vertical blank.';

  FInfoMemo := TMemo.Create(Self);
  FInfoMemo.Parent := Tab;
  FInfoMemo.Align := alClient;
  FInfoMemo.ReadOnly := True;
  FInfoMemo.ScrollBars := ssBoth;
  FInfoMemo.WordWrap := False;
  FInfoMemo.Font.Name := 'Consolas';
  FInfoMemo.Font.Size := 9;
end;

{ --------------------------------------------------------------- refresh }

function TMainForm.CompositePasses: TPassSet;
var
  i: integer;
begin
  Result := [];
  for i := 0 to PassCount - 1 do
    if FHex.Passes[i]^.Enabled then Include(Result, i);
end;

procedure TMainForm.RefreshParamControls;
var
  i: integer;
  P: TParamInfo;
begin
  FUpdating := True;
  try
    for i := 0 to High(FParamRows) do
    begin
      P := FHex.Params[i];
      if P.Kind = pkFloat then
      begin
        FParamRows[i].Spin.Value := P.PValue^;
        FParamRows[i].Track.Position := Round((P.PValue^ - P.Min) / (P.Max - P.Min) * 1000);
      end
      else
      begin
        FParamRows[i].ColorBtn.ButtonColor := BGRAToColor(P.PColor^);
        FParamRows[i].Alpha.Value := P.PColor^.alpha;
      end;
    end;
    FSeedEdit.Value := FHex.Seed;
    for i := 0 to PassCount - 1 do
      FPassRows[i].Check.Checked := FHex.Passes[i]^.Enabled;
  finally
    FUpdating := False;
  end;
end;

// One pass rendered alone, at thumbnail size, with the live camera.
procedure TMainForm.RefreshThumb(i: integer);
var
  T: TBGRABitmap;
  B: TBitmap;
begin
  T := TBGRABitmap.Create(ThumbW, ThumbH);
  B := TBitmap.Create;     // a new TBitmap per row: Assign shares image data
  try
    FHex.Render(T, ThumbW, ThumbH, [i], True, False);
    B.SetSize(ThumbW, ThumbH);
    T.Draw(B.Canvas, 0, 0, True);
    FPassRows[i].Thumb.Picture.Assign(B);
  finally
    B.Free;
    T.Free;
  end;
end;

procedure TMainForm.RefreshPassRow(i: integer);
var
  Sel: boolean;
  Txt: string;
begin
  with FHex.Passes[i]^ do
    if (i = psGlow) and Enabled and FHex.Passes[psFront]^.Enabled and (FViewCombo.ItemIndex <= 0) then
      Txt := Format('%d halos'#13'baked into the front-face sprites'#13 +
        '(time counted in pass 5)', [Items])
    else
      Txt := Format('%d items drawn'#13'%.2f ms per frame'#13'%s',
        [Items, TimeMs, BoolToStr(Enabled, 'in the final image', 'switched off')]);
  // only touch the label when its text really changed
  if FPassRows[i].Stats.Caption <> Txt then FPassRows[i].Stats.Caption := Txt;
  Sel := FViewCombo.ItemIndex = i + 1;
  if Sel then FPassRows[i].Panel.Color := clHighlight else FPassRows[i].Panel.Color := clDefault;
  if Sel then FPassRows[i].Title.Font.Color := clHighlightText else FPassRows[i].Title.Font.Color := clDefault;
  FPassRows[i].Stats.Font.Color := FPassRows[i].Title.Font.Color;
end;

procedure TMainForm.RefreshPassRows(WithThumbs: boolean);
var
  i: integer;
begin
  for i := 0 to PassCount - 1 do
  begin
    if WithThumbs then RefreshThumb(i);
    RefreshPassRow(i);
  end;
end;

procedure TMainForm.RefreshInfo;
begin
  FLastInfo := GetTickCount64;
  FInfoMemo.Lines.BeginUpdate;
  try
    FInfoMemo.Lines.Text := FHex.Report(FFps);
  finally
    FInfoMemo.Lines.EndUpdate;
  end;
end;

procedure TMainForm.InfoRefreshClick(Sender: TObject);
begin
  RefreshInfo;
end;

procedure TMainForm.RenderFrame;
var
  W, H, i: integer;
begin
  W := Max(16, Round(FOutput.Width * FHex.Settings^.RenderScale));
  H := Max(16, Round(FOutput.Height * FHex.Settings^.RenderScale));
  i := FViewCombo.ItemIndex - 1;
  if i < 0 then
    FHex.Render(FFrame, W, H, CompositePasses, False, True)
  else
    FHex.Render(FFrame, W, H, [i], True, True);
  Present;
end;

procedure TMainForm.Present;
var
  t: double;
begin
  t := NowMs;
  if FUseGL then
    try
      PresentGL;
    except
      on E: Exception do UseGDI(E.Message);
    end
  else
    FView.Repaint;
  FShowMs := FShowMs * 0.9 + (NowMs - t - FWaitMs) * 0.1;
end;

procedure TMainForm.UseGDI(const Reason: string);
begin
  FUseGL := False;
  if FGL <> nil then FGL.Visible := False;
  FView.Visible := True;
  FOutput := FView;
  FWaitMs := 0;
  if FVSyncCheck <> nil then
  begin
    FVSyncCheck.Checked := False;
    FVSyncCheck.Enabled := False;
    FVSyncCheck.Hint := 'OpenGL is not available: ' + Reason;
  end;
end;

// Upload the frame as a texture and draw it as one quad; SwapBuffers then
// waits for the vertical blank when vsync is on.
procedure TMainForm.PresentGL;
type
  TSwapInterval = function(Interval: longint): LongBool; stdcall;
const
  GL_BGRA = $80E1;                   // OpenGL 1.2 constants, not in the GL 1.1 unit
  GL_CLAMP_TO_EDGE = $812F;
var
  SwapInterval: TSwapInterval;
  v0, v1, t: double;
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
    FVSyncApplied := not FVSync;
  end;
  if FVSyncApplied <> FVSync then
  begin
    {$IFDEF WINDOWS}
    Pointer(SwapInterval) := wglGetProcAddress('wglSwapIntervalEXT');
    FVSyncSupported := Assigned(SwapInterval);
    if FVSyncSupported then SwapInterval(Ord(FVSync));
    {$ENDIF}
    FVSyncApplied := FVSync;
  end;

  glViewport(0, 0, FGL.Width, FGL.Height);
  glBindTexture(GL_TEXTURE_2D, FTexture);
  // TBGRAPixel memory order on Windows is B, G, R, A: uploaded as is
  if (FTexW <> FFrame.Width) or (FTexH <> FFrame.Height) then
  begin
    FTexW := FFrame.Width;
    FTexH := FFrame.Height;
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, FTexW, FTexH, 0, GL_BGRA, GL_UNSIGNED_BYTE, FFrame.Data);
  end
  else
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, FTexW, FTexH, GL_BGRA, GL_UNSIGNED_BYTE, FFrame.Data);

  // GL textures start at the bottom row; flip if the bitmap is stored top-down
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

  t := NowMs;
  FGL.SwapBuffers;
  glFinish;                          // do not let the driver queue frames ahead
  FWaitMs := FWaitMs * 0.9 + (NowMs - t) * 0.1;
end;

procedure TMainForm.GLPaint(Sender: TObject);
begin
  // window exposed or resized between frames: show the last frame again
  if FUseGL and (FFrame.Width > 16) then
    try
      PresentGL;
    except
      on E: Exception do UseGDI(E.Message);
    end;
end;

procedure TMainForm.VSyncClick(Sender: TObject);
begin
  FVSync := FVSyncCheck.Checked;
  FNextFrame := NowMs;
end;

{ ---------------------------------------------------------------- events }

procedure TMainForm.AppIdle(Sender: TObject; var Done: boolean);
var
  Now: double;
begin
  Done := False;                     // keep the idle loop running
  if FUseGL and FVSync then
  begin
    // SwapBuffers waits for the vertical blank: the display sets the pace
    DoFrame;
    Exit;
  end;
  Now := NowMs;
  if Now < FNextFrame then
  begin
    // wait for the next 60 Hz slot; spin the last millisecond for accuracy
    if FNextFrame - Now > 1.5 then Sleep(1);
    Exit;
  end;
  // fixed schedule: frames stay on a steady 16.7 ms grid
  FNextFrame := FNextFrame + 1000 / MaxFps;
  if FNextFrame < Now then FNextFrame := Now + 1000 / MaxFps;   // fell behind: resync
  DoFrame;
end;

procedure TMainForm.DoFrame;
var
  Now: QWord;
  t: double;

  function OutputName: string;
  begin
    if not FUseGL then
      Result := 'GDI (no vsync)'
    else if FVSync and FVSyncSupported then
      Result := Format('OpenGL vsync %d Hz', [FRefreshHz])
    else if FVSync then
      Result := 'OpenGL (vsync not supported)'
    else
      Result := 'OpenGL, vsync off';
  end;

begin
  Now := GetTickCount64;
  t := NowMs;
  // caches are rebuilt once the user stops dragging a slider
  if (FPending <> []) and (Now - FPendingAt > 150) then
  begin
    FHex.Invalidate(FPending);
    FPending := [];
  end;
  // with vsync, a frame that took longer than 1.5 refresh periods missed a vblank
  if FUseGL and FVSync and (FRefreshHz > 0) and (FFrames > 0) and
    (t - FLastTick > 1.5 * 1000 / FRefreshHz) then
  begin
    Inc(FDropped);
    Inc(FDroppedTotal);
  end;
  if FPaused then
    FHex.Animate(0)
  else
    FHex.Animate(Min(0.1, (t - FLastTick) / 1000));
  FLastTick := t;
  RenderFrame;
  Inc(FFrames);

  // thumbnails: one per frame, a full round every 1.5 s, so no single frame
  // pays for all eight
  if FPages.ActivePage = FPassTab then
    if (FThumbNext > 0) or (Now - FLastThumbs >= 1500) then
    begin
      RefreshThumb(FThumbNext);
      Inc(FThumbNext);
      if FThumbNext >= PassCount then
      begin
        FThumbNext := 0;
        FLastThumbs := Now;
      end;
    end;

  if t - FLastStatus >= 500 then
  begin
    FFps := (FFrames - 1) * 1000 / (FLastTick - FLastStatus);
    with FHex.Stats do
      FStatus.Caption := Format('%.1f fps (%d dropped, %d total)  |  %s  |  %.1f ms = list %.1f + draw %.1f (%d threads) + show %.1f' +
        '  (+ vsync wait %.1f)  |  %d x %d  |  %d hexagons  |  %d sprites (%.0f MB, %d borrowed)',
        [FFps, FDropped, FDroppedTotal, OutputName, FrameMs + FShowMs, SetupMs, DrawMs, Threads, FShowMs, FWaitMs,
         FFrame.Width, FFrame.Height, Visible, FHex.SpriteCount, FHex.SpriteBytes / 1048576, Borrowed]);
    FFrames := 1;
    FDropped := 0;
    FLastStatus := t;
  end;
  // pass rows: one row every 4th frame (each row about twice a second)
  if (FPages.ActivePage = FPassTab) and (FFrames mod 4 = 0) then
  begin
    RefreshPassRow(FRowNext);
    FRowNext := (FRowNext + 1) mod PassCount;
  end;
  if (FPages.ActivePage = FInfoTab) and FInfoAuto.Checked and (Now - FLastInfo >= 2000) then
    RefreshInfo;
end;

procedure TMainForm.ViewPaint(Sender: TObject);
begin
  if (FFrame.Width = FView.Width) and (FFrame.Height = FView.Height) then
    FFrame.Draw(FView.Canvas, 0, 0, True)
  else
    FFrame.Draw(FView.Canvas, Rect(0, 0, FView.Width, FView.Height), True);
end;

procedure TMainForm.ViewMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: integer);
begin
  ActiveControl := nil;     // hand the hotkeys back to the form
end;

procedure TMainForm.ViewMouseMove(Sender: TObject; Shift: TShiftState; X, Y: integer);
begin
  if (FOutput.Width > 0) and (FOutput.Height > 0) then
    FHex.SetMouse(X / FOutput.Width * 2 - 1, Y / FOutput.Height * 2 - 1);
end;

procedure TMainForm.ViewMouseLeave(Sender: TObject);
begin
  FHex.SetMouse(0, 0);
end;

procedure TMainForm.PassCheckClick(Sender: TObject);
begin
  if FUpdating then Exit;
  FHex.Passes[TCheckBox(Sender).Tag]^.Enabled := TCheckBox(Sender).Checked;
  RefreshPassRows(False);
end;

procedure TMainForm.PassRowClick(Sender: TObject);
var
  i: integer;
begin
  i := TControl(Sender).Tag + 1;
  if FViewCombo.ItemIndex = i then i := 0;    // click again = back to composite
  FViewCombo.ItemIndex := i;
  ViewComboChange(nil);
end;

procedure TMainForm.ViewComboChange(Sender: TObject);
begin
  RefreshPassRows(False);
end;

procedure TMainForm.ParamChanged(Index: integer);
begin
  if FHex.Params[Index].Effects = [] then Exit;     // read live every frame
  FPending := FPending + FHex.Params[Index].Effects;
  FPendingAt := GetTickCount64;
end;

procedure TMainForm.TrackChange(Sender: TObject);
var
  i: integer;
  P: TParamInfo;
begin
  if FUpdating then Exit;
  i := TTrackBar(Sender).Tag;
  P := FHex.Params[i];
  P.PValue^ := RoundTo(P.Min + TTrackBar(Sender).Position / 1000 * (P.Max - P.Min), -P.Decimals);
  FUpdating := True;
  FParamRows[i].Spin.Value := P.PValue^;
  FUpdating := False;
  ParamChanged(i);
end;

procedure TMainForm.SpinChange(Sender: TObject);
var
  i: integer;
  P: TParamInfo;
begin
  if FUpdating then Exit;
  i := TFloatSpinEdit(Sender).Tag;
  P := FHex.Params[i];
  P.PValue^ := TFloatSpinEdit(Sender).Value;
  FUpdating := True;
  FParamRows[i].Track.Position := Round((P.PValue^ - P.Min) / (P.Max - P.Min) * 1000);
  FUpdating := False;
  ParamChanged(i);
end;

procedure TMainForm.ColorChanged(Sender: TObject);
var
  i: integer;
begin
  if FUpdating then Exit;
  i := TControl(Sender).Tag;
  FHex.Params[i].PColor^ := ColorToBGRA(ColorToRGB(FParamRows[i].ColorBtn.ButtonColor),
    FParamRows[i].Alpha.Value);
  ParamChanged(i);
end;

procedure TMainForm.SeedChange(Sender: TObject);
begin
  if FUpdating then Exit;
  FHex.SetSeed(FSeedEdit.Value);
end;

procedure TMainForm.NewSeedClick(Sender: TObject);
begin
  Randomize;
  FSeedEdit.Value := Random(MaxInt);     // triggers SeedChange
end;

procedure TMainForm.ResetClick(Sender: TObject);
begin
  FHex.ResetDefaults;
  FPending := [];
  RefreshParamControls;
end;

procedure TMainForm.PauseClick(Sender: TObject);
begin
  FPaused := not FPaused;
  if FPaused then FPauseBtn.Caption := 'Play' else FPauseBtn.Caption := 'Pause';
end;

procedure TMainForm.SavePngClick(Sender: TObject);
var
  FileName: string;
  Bmp: TBGRABitmap;
begin
  Bmp := TBGRABitmap.Create(1, 1);
  try
    // exact sprites for the saved image, not borrowed neighbours
    FHex.AsyncSprites := False;
    try
      FHex.Render(Bmp, FOutput.Width, FOutput.Height, CompositePasses, False, False);
    finally
      FHex.AsyncSprites := True;
    end;
    FileName := ExtractFilePath(Application.ExeName) +
      Format('hexbg_%dx%d_%d_t%.0f.png', [Bmp.Width, Bmp.Height, FHex.Seed, FHex.Time]);
    Bmp.SaveToFile(FileName);
  finally
    Bmp.Free;
  end;
  FStatus.Caption := 'Saved ' + FileName;
end;

procedure TMainForm.SaveIniClick(Sender: TObject);
begin
  with TSaveDialog.Create(Self) do
  try
    Filter := 'Hex background settings (*.ini)|*.ini';
    DefaultExt := 'ini';
    FileName := 'hexbg.ini';
    InitialDir := ExtractFilePath(Application.ExeName);
    if Execute then
      FHex.SaveToIni(FileName);
  finally
    Free;
  end;
end;

procedure TMainForm.LoadIniClick(Sender: TObject);
begin
  with TOpenDialog.Create(Self) do
  try
    Filter := 'Hex background settings (*.ini)|*.ini';
    InitialDir := ExtractFilePath(Application.ExeName);
    if Execute then
    begin
      FHex.LoadFromIni(FileName);
      FPending := [];
      RefreshParamControls;
    end;
  finally
    Free;
  end;
end;

procedure TMainForm.CopyInfoClick(Sender: TObject);
begin
  Clipboard.AsText := FHex.Report(FFps);
end;

procedure TMainForm.ToggleFullScreen;
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

procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_F2:
      begin
        FSide.Visible := not FSide.Visible;
        FSplitter.Visible := FSide.Visible;
        if FSide.Visible then FSplitter.Left := FSide.Left - 1;
      end;
    VK_F11:
      ToggleFullScreen;
    VK_ESCAPE:
      if FFullScreen then ToggleFullScreen else ActiveControl := nil;
  else
    // letter hotkeys only when no edit / slider has the focus
    if ActiveControl <> nil then Exit;
    case Key of
      VK_R: NewSeedClick(nil);
      VK_S: SavePngClick(nil);
      VK_SPACE: PauseClick(nil);
    else
      Exit;
    end;
  end;
  Key := 0;
end;

end.
