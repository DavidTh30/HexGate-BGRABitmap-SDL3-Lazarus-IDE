unit UGateMain;

{ HexGate window: full-window OpenGL view (vsync), sound, input.

  Main menu: mouse or Up/Down + Enter, Esc = exit. Options: Left/Right or
  click to change, right click goes back a value, Esc = back.
  In game: mouse / WASD / arrows steer, hold Space to boost, P pause,
  Esc pause / main menu. Everywhere: F11 fullscreen, F12 save a PNG,
  F9 export all graphics data to hexgate_graphics.json (ugfxexport.pas).
  The game pauses itself when the window loses focus. }

{$mode objfpc}{$H+}

interface

uses
  {$IFDEF WINDOWS}Windows, MMSystem,{$ENDIF}
  Classes, SysUtils, Math, Forms, Controls, Graphics, GraphType, ExtCtrls, LCLType,
  GL, OpenGLContext, BGRABitmap, BGRABitmapTypes, UHexBackground, UGateGame, UGateAudio,
  UGfxExport;

type

  { TGateForm }

  TGateForm = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
  private
    FHex: THexBackground;
    FGame: TGateGame;
    FAudio: TGateAudio;
    FFrames: integer;
    FFpsStart, FHudMs, FShowMs: double;
    FFrame: TBGRABitmap;
    FGL: TOpenGLControl;             // OpenGL output (vsync)
    FView: TPaintBox;                // GDI fallback output
    FOutput: TControl;
    FUseGL, FGLReady, FVSyncSet, FFullScreen: boolean;
    FTexture: GLuint;
    FTexW, FTexH: integer;
    FLastTick, FNextFrame: double;
    FSavedBounds: TRect;
    procedure AppIdle(Sender: TObject; var Done: boolean);
    procedure AppDeactivate(Sender: TObject);
    procedure DoFrame;
    procedure Present;
    procedure PresentGL;
    procedure UseGDI;
    procedure GLPaint(Sender: TObject);
    procedure ViewPaint(Sender: TObject);
    procedure OutputMouseMove(Sender: TObject; Shift: TShiftState; X, Y: integer);
    procedure OutputMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: integer);
    procedure SetKey(Key: Word; Down: boolean);
    procedure SavePng;
    procedure ToggleFullScreen;
  end;

var
  GateForm: TGateForm;

implementation

{$R *.lfm}

const
  FallbackFps = 60;                  // frame rate without vsync

{ TGateForm }

procedure TGateForm.FormCreate(Sender: TObject);
begin
  Caption := 'HexGate';
  FHex := THexBackground.Create;
  FHex.AsyncSprites := True;         // big sprites are built in the background
  FAudio := TGateAudio.Create;       // synthesized music and sound effects
  FGame := TGateGame.Create(FHex, FAudio, ChangeFileExt(Application.ExeName, '.ini'));
  FFrame := TBGRABitmap.Create(16, 16, BGRABlack);

  FView := TPaintBox.Create(Self);
  FView.Parent := Self;
  FView.Align := alClient;
  FView.Visible := False;
  FView.OnPaint := @ViewPaint;
  FView.OnMouseMove := @OutputMouseMove;
  FView.OnMouseDown := @OutputMouseDown;
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
    FOutput := FGL;
  except
    UseGDI;
  end;

  {$IFDEF WINDOWS}
  timeBeginPeriod(1);                // Sleep(1) really sleeps ~1 ms
  {$ENDIF}
  FLastTick := NowMs;
  FNextFrame := FLastTick;
  FFpsStart := FLastTick;
  Application.AddOnIdleHandler(@AppIdle);
  Application.AddOnDeactivateHandler(@AppDeactivate);
end;

procedure TGateForm.FormDestroy(Sender: TObject);
begin
  Application.RemoveOnIdleHandler(@AppIdle);
  Application.RemoveOnDeactivateHandler(@AppDeactivate);
  {$IFDEF WINDOWS}
  timeEndPeriod(1);
  {$ENDIF}
  FGame.Free;
  FAudio.Free;
  FFrame.Free;
  FHex.Free;
end;

{ ----------------------------------------------------------------- frames }

procedure TGateForm.AppIdle(Sender: TObject; var Done: boolean);
var
  Now: double;
begin
  Done := False;                     // keep the idle loop running
  if FUseGL then
  begin
    // SwapBuffers waits for the vertical blank: the display sets the pace
    DoFrame;
    Exit;
  end;
  Now := NowMs;
  if Now < FNextFrame then
  begin
    if FNextFrame - Now > 1.5 then Sleep(1);
    Exit;
  end;
  FNextFrame := FNextFrame + 1000 / FallbackFps;
  if FNextFrame < Now then FNextFrame := Now + 1000 / FallbackFps;
  DoFrame;
end;

procedure TGateForm.AppDeactivate(Sender: TObject);
begin
  if FGame.State = gsPlaying then FGame.TogglePause;
end;

procedure TGateForm.DoFrame;
var
  t, dt, t1, t2: double;
  W, H: integer;
  Want: TCursor;
begin
  t := NowMs;
  dt := Min(0.1, (t - FLastTick) / 1000);
  FLastTick := t;
  Inc(FFrames);
  if t - FFpsStart >= 500 then
  begin
    FGame.Fps := FFrames * 1000 / (t - FFpsStart);
    with FHex.Stats do
      FGame.FpsDetail := Format('%dx%d  list %.1f  draw %.1f  hud %.1f  show+vsync %.1f ms',
        [FFrame.Width, FFrame.Height, SetupMs, DrawMs, FHudMs, FShowMs]);
    FFrames := 0;
    FFpsStart := t;
  end;
  // options chosen in the menu
  if FGame.RequestExit then
  begin
    FGame.RequestExit := False;
    Close;
    Exit;
  end;
  if FGame.Options.Fullscreen <> FFullScreen then ToggleFullScreen;
  FGame.Update(dt);
  if FGame.State = gsPaused then
    FHex.Animate(0)
  else
    FHex.Animate(dt);
  W := Max(16, Round(FOutput.Width * FHex.Settings^.RenderScale));
  H := Max(16, Round(FOutput.Height * FHex.Settings^.RenderScale));
  FHex.Render(FFrame, W, H, [0..PassCount - 1], False, True);
  t1 := NowMs;
  FGame.DrawHud(FFrame);
  t2 := NowMs;
  Present;
  FHudMs := FHudMs * 0.9 + (t2 - t1) * 0.1;
  FShowMs := FShowMs * 0.9 + (NowMs - t2) * 0.1;

  // no mouse pointer over the picture while flying
  if FGame.State = gsPlaying then Want := crNone else Want := crDefault;
  if FOutput.Cursor <> Want then FOutput.Cursor := Want;
end;

procedure TGateForm.Present;
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

procedure TGateForm.UseGDI;
begin
  FUseGL := False;
  if FGL <> nil then FGL.Visible := False;
  FView.Visible := True;
  FOutput := FView;
  FNextFrame := NowMs;
end;

// Upload the frame as a texture and draw it as one quad; SwapBuffers then
// waits for the vertical blank.
procedure TGateForm.PresentGL;
type
  TSwapInterval = function(Interval: longint): LongBool; stdcall;
const
  GL_BGRA = $80E1;                   // OpenGL 1.2 constants, not in the GL 1.1 unit
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
  FGL.SwapBuffers;
  glFinish;                          // do not let the driver queue frames ahead
end;

procedure TGateForm.GLPaint(Sender: TObject);
begin
  // window exposed or resized between frames: show the last frame again
  if FUseGL and (FFrame.Width > 16) then
    try
      PresentGL;
    except
      UseGDI;
    end;
end;

procedure TGateForm.ViewPaint(Sender: TObject);
begin
  FFrame.Draw(FView.Canvas, Rect(0, 0, FView.Width, FView.Height), True);
end;

{ ------------------------------------------------------------------ input }

procedure TGateForm.OutputMouseMove(Sender: TObject; Shift: TShiftState; X, Y: integer);
begin
  if (FOutput.Width > 0) and (FOutput.Height > 0) then
  begin
    FGame.MouseX := EnsureRange(X / FOutput.Width * 2 - 1, -1, 1);
    FGame.MouseY := EnsureRange(Y / FOutput.Height * 2 - 1, -1, 1);
    FGame.MouseActive := True;
  end;
end;

procedure TGateForm.OutputMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: integer);
begin
  if Button in [mbLeft, mbRight] then FGame.Click(Button = mbRight);
end;

procedure TGateForm.SetKey(Key: Word; Down: boolean);
begin
  case Key of
    VK_LEFT, VK_A: FGame.KeyLeft := Down;
    VK_RIGHT, VK_D: FGame.KeyRight := Down;
    VK_UP, VK_W: FGame.KeyUp := Down;
    VK_DOWN, VK_S: FGame.KeyDown := Down;
    VK_SPACE: FGame.KeyBoost := Down;
  end;
end;

procedure TGateForm.SavePng;
var
  Bmp: TBGRABitmap;
begin
  Bmp := TBGRABitmap.Create(1, 1);
  try
    // exact sprites for the saved image, not borrowed neighbours
    FHex.AsyncSprites := False;
    try
      FHex.Render(Bmp, FOutput.Width, FOutput.Height, [0..PassCount - 1], False, False);
    finally
      FHex.AsyncSprites := True;
    end;
    FGame.DrawHud(Bmp);
    Bmp.SaveToFile(ExtractFilePath(Application.ExeName) +
      Format('hexgate_%s.png', [FormatDateTime('yyyymmdd_hhnnss', Now)]));
  finally
    Bmp.Free;
  end;
end;

procedure TGateForm.ToggleFullScreen;
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

procedure TGateForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  SetKey(Key, True);
  case Key of
    VK_F11:
      begin
        ToggleFullScreen;
        FGame.SetFullscreen(FFullScreen);
      end;
    VK_F12: SavePng;
    VK_F9:
      begin
        Screen.Cursor := crHourGlass;
        try
          ExportGraphics(FHex, FGame, ExtractFilePath(Application.ExeName) + 'hexgate_graphics.json');
        finally
          Screen.Cursor := crDefault;
        end;
        FGame.Notify('GRAPHICS EXPORTED');
      end;
    VK_ESCAPE: FGame.Escape;
  else
    if FGame.State = gsTitle then
      FGame.MenuKey(Key)
    else
      case Key of
        VK_SPACE, VK_RETURN: FGame.Start;      // game over: play again
        VK_P: FGame.TogglePause;
      end;
  end;
  Key := 0;
end;

procedure TGateForm.FormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  SetKey(Key, False);
  Key := 0;
end;

end.
