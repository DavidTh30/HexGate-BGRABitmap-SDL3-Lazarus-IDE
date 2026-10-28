unit UHexFlightMain;

{ HexFlight - the hexagon camera fly-through as a plain full-window
  background. No inspector panel: the whole window is the picture.

  Output: the frame is uploaded to an OpenGL texture and drawn as one quad;
  SwapBuffers with swap interval 1 waits for the vertical blank (no tearing,
  the display paces the animation). Without OpenGL it falls back to GDI on a
  60 Hz timer grid.

  Settings: if HexFlight.ini exists next to the program it is loaded at start
  (it has the same format as "Save settings..." in Hex Background).

  Mouse steers the camera. Keys: R new seed, S save PNG, Space pause,
  F11 fullscreen, Esc leave fullscreen / quit. }

{$mode objfpc}{$H+}

interface

uses
  {$IFDEF WINDOWS}Windows, MMSystem,{$ENDIF}
  Classes, SysUtils, Math, Forms, Controls, Graphics, GraphType, ExtCtrls, LCLType,
  GL, OpenGLContext, BGRABitmap, BGRABitmapTypes, UHexBackground;

type

  { TFlightForm }

  TFlightForm = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
  private
    FHex: THexBackground;
    FFrame: TBGRABitmap;
    FGL: TOpenGLControl;             // OpenGL output (vsync)
    FView: TPaintBox;                // GDI fallback output
    FOutput: TControl;
    FUseGL, FGLReady, FVSyncSet, FPaused, FFullScreen: boolean;
    FTexture: GLuint;
    FTexW, FTexH: integer;
    FLastTick, FNextFrame: double;
    FSavedBounds: TRect;
    procedure AppIdle(Sender: TObject; var Done: boolean);
    procedure DoFrame;
    procedure Present;
    procedure PresentGL;
    procedure UseGDI;
    procedure GLPaint(Sender: TObject);
    procedure ViewPaint(Sender: TObject);
    procedure OutputMouseMove(Sender: TObject; Shift: TShiftState; X, Y: integer);
    procedure OutputMouseLeave(Sender: TObject);
    procedure SavePng;
    procedure ToggleFullScreen;
  end;

var
  FlightForm: TFlightForm;

implementation

{$R *.lfm}

const
  FallbackFps = 60;                  // frame rate without vsync

{ TFlightForm }

procedure TFlightForm.FormCreate(Sender: TObject);
var
  Ini: string;
begin
  Caption := 'HexFlight';
  FHex := THexBackground.Create;
  Ini := ChangeFileExt(Application.ExeName, '.ini');
  if FileExists(Ini) then FHex.LoadFromIni(Ini);
  FHex.AsyncSprites := True;         // big sprites are built in the background
  FFrame := TBGRABitmap.Create(16, 16, BGRABlack);

  FView := TPaintBox.Create(Self);
  FView.Parent := Self;
  FView.Align := alClient;
  FView.Visible := False;
  FView.OnPaint := @ViewPaint;
  FView.OnMouseMove := @OutputMouseMove;
  FView.OnMouseLeave := @OutputMouseLeave;
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
    FGL.OnMouseLeave := @OutputMouseLeave;
    FOutput := FGL;
  except
    UseGDI;
  end;

  {$IFDEF WINDOWS}
  timeBeginPeriod(1);                // Sleep(1) really sleeps ~1 ms
  {$ENDIF}
  FLastTick := NowMs;
  FNextFrame := FLastTick;
  Application.AddOnIdleHandler(@AppIdle);
end;

procedure TFlightForm.FormDestroy(Sender: TObject);
begin
  Application.RemoveOnIdleHandler(@AppIdle);
  {$IFDEF WINDOWS}
  timeEndPeriod(1);
  {$ENDIF}
  FFrame.Free;
  FHex.Free;
end;

{ ----------------------------------------------------------------- frames }

procedure TFlightForm.AppIdle(Sender: TObject; var Done: boolean);
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

procedure TFlightForm.DoFrame;
var
  t: double;
  W, H: integer;
begin
  t := NowMs;
  if FPaused then
    FHex.Animate(0)
  else
    FHex.Animate(Min(0.1, (t - FLastTick) / 1000));
  FLastTick := t;
  W := Max(16, Round(FOutput.Width * FHex.Settings^.RenderScale));
  H := Max(16, Round(FOutput.Height * FHex.Settings^.RenderScale));
  FHex.Render(FFrame, W, H, [0..PassCount - 1], False, False);
  Present;
end;

procedure TFlightForm.Present;
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

procedure TFlightForm.UseGDI;
begin
  FUseGL := False;
  if FGL <> nil then FGL.Visible := False;
  FView.Visible := True;
  FOutput := FView;
  FNextFrame := NowMs;
end;

// Upload the frame as a texture and draw it as one quad; SwapBuffers then
// waits for the vertical blank.
procedure TFlightForm.PresentGL;
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

procedure TFlightForm.GLPaint(Sender: TObject);
begin
  // window exposed or resized between frames: show the last frame again
  if FUseGL and (FFrame.Width > 16) then
    try
      PresentGL;
    except
      UseGDI;
    end;
end;

procedure TFlightForm.ViewPaint(Sender: TObject);
begin
  FFrame.Draw(FView.Canvas, Rect(0, 0, FView.Width, FView.Height), True);
end;

{ ------------------------------------------------------------------ input }

procedure TFlightForm.OutputMouseMove(Sender: TObject; Shift: TShiftState; X, Y: integer);
begin
  if (FOutput.Width > 0) and (FOutput.Height > 0) then
    FHex.SetMouse(X / FOutput.Width * 2 - 1, Y / FOutput.Height * 2 - 1);
end;

procedure TFlightForm.OutputMouseLeave(Sender: TObject);
begin
  FHex.SetMouse(0, 0);
end;

procedure TFlightForm.SavePng;
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
    Bmp.SaveToFile(ExtractFilePath(Application.ExeName) +
      Format('hexflight_%dx%d_%d_t%.0f.png', [Bmp.Width, Bmp.Height, FHex.Seed, FHex.Time]));
  finally
    Bmp.Free;
  end;
end;

procedure TFlightForm.ToggleFullScreen;
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

procedure TFlightForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_R:
      begin
        Randomize;
        FHex.SetSeed(Random(MaxInt));
      end;
    VK_S: SavePng;
    VK_SPACE: FPaused := not FPaused;
    VK_F11: ToggleFullScreen;
    VK_ESCAPE:
      if FFullScreen then ToggleFullScreen else Close;
  else
    Exit;
  end;
  Key := 0;
end;

end.
