program HexFlightSDL3;

{ HexFlight (SDL3) - the hexagon camera fly-through as a full-window
  background, on SDL3 instead of the LCL.

  The picture is rendered by the HexFlight engine (uhexbackground.pas:
  BGRABitmap, all CPU cores, sprites built in the background). SDL3 only
  provides the window, the input and the output:
    - the finished frame is copied into a streaming texture
      (SDL_PIXELFORMAT_ARGB8888 = BGRABitmap's B, G, R, A byte order, so no
      conversion) and drawn stretched over the window by the GPU;
    - SDL_SetRenderVSync(1) makes SDL_RenderPresent wait for the vertical
      blank: no tearing, the display paces the animation.

  Settings: HexFlight.ini next to the program, if present (same format as
  "Save settings..." in Hex Background).

  Mouse steers the camera. Keys: R new seed, S save PNG, Space pause,
  F11 fullscreen, Esc leave fullscreen / quit.
  The window title shows the frame rate.

  Needs SDL3.dll next to the program. }

{$mode objfpc}{$H+}
{$IFDEF WINDOWS}{$APPTYPE GUI}{$ENDIF}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, Math, SDL3, BGRABitmap, BGRABitmapTypes, UHexBackground;

const
  AppName = 'HexFlight (SDL3)';
  StartW = 1280;
  StartH = 720;

var
  Window: PSDL_Window;
  Renderer: PSDL_Renderer;
  Texture: PSDL_Texture = nil;
  TexW: integer = 0;
  TexH: integer = 0;
  Hex: THexBackground;
  Frame: TBGRABitmap;
  Running: boolean = True;
  Paused: boolean = False;
  FullScreen: boolean = False;
  VSyncOn: boolean;
  Frames: integer = 0;
  LastTick, FpsStart: double;

procedure Fail(const What: string);
begin
  SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, AppName,
    PAnsiChar(AnsiString(What + ': ' + string(SDL_GetError))), nil);
  SDL_Quit;
  Halt(1);
end;

// Draw size of the window in pixels (differs from its size on high-DPI screens).
procedure OutputSize(out W, H: integer);
begin
  W := 0;
  H := 0;
  SDL_GetRenderOutputSize(Renderer, @W, @H);
  W := Max(W, 16);
  H := Max(H, 16);
end;

procedure SavePng;
var
  Bmp: TBGRABitmap;
  W, H: integer;
begin
  OutputSize(W, H);
  Bmp := TBGRABitmap.Create(1, 1);
  try
    // exact sprites for the saved image, not borrowed neighbours
    Hex.AsyncSprites := False;
    try
      Hex.Render(Bmp, W, H, [0..PassCount - 1], False, False);
    finally
      Hex.AsyncSprites := True;
    end;
    Bmp.SaveToFile(ExtractFilePath(ParamStr(0)) +
      Format('hexflight_%dx%d_%d_t%.0f.png', [W, H, Hex.Seed, Hex.Time]));
  finally
    Bmp.Free;
  end;
end;

procedure HandleEvents;
var
  E: TSDL_Event;
  W, H: longint;
begin
  FillChar(E, SizeOf(E), 0);
  while SDL_PollEvent(@E) do
    case E._type of
      SDL_EVENT_QUIT:
        Running := False;
      SDL_EVENT_KEY_DOWN:
        case E.key.key of
          SDLK_ESCAPE:
            if FullScreen then
            begin
              FullScreen := False;
              SDL_SetWindowFullscreen(Window, False);
            end
            else
              Running := False;
          SDLK_F11:
            begin
              FullScreen := not FullScreen;
              SDL_SetWindowFullscreen(Window, FullScreen);
            end;
          SDLK_SPACE: Paused := not Paused;
          SDLK_R:
            begin
              Randomize;
              Hex.SetSeed(Random(MaxInt));
            end;
          SDLK_S: SavePng;
        end;
      SDL_EVENT_MOUSE_MOTION:
        begin
          // window coordinates (not pixels): compare with the window size
          SDL_GetWindowSize(Window, @W, @H);
          if (W > 0) and (H > 0) then
            Hex.SetMouse(E.motion.x / W * 2 - 1, E.motion.y / H * 2 - 1);
        end;
      SDL_EVENT_WINDOW_MOUSE_LEAVE:
        Hex.SetMouse(0, 0);
    end;
end;

procedure DrawFrame;
var
  W, H, FW, FH: integer;
  t: double;
  BottomUp: boolean;
begin
  t := NowMs;
  if Paused then
    Hex.Animate(0)
  else
    Hex.Animate(Min(0.1, (t - LastTick) / 1000));
  LastTick := t;

  OutputSize(W, H);
  FW := Max(16, Round(W * Hex.Settings^.RenderScale));
  FH := Max(16, Round(H * Hex.Settings^.RenderScale));
  Hex.Render(Frame, FW, FH, [0..PassCount - 1], False, False);

  if (Texture = nil) or (TexW <> FW) or (TexH <> FH) then
  begin
    if Texture <> nil then SDL_DestroyTexture(Texture);
    Texture := SDL_CreateTexture(Renderer, SDL_PIXELFORMAT_ARGB8888,
      SDL_TEXTUREACCESS_STREAMING, FW, FH);
    if Texture = nil then Fail('SDL_CreateTexture');
    SDL_SetTextureScaleMode(Texture, SDL_SCALEMODE_LINEAR);
    TexW := FW;
    TexH := FH;
  end;
  SDL_UpdateTexture(Texture, nil, Frame.Data, FW * SizeOf(TBGRAPixel));

  // some BGRABitmap builds store the rows bottom-up: let the GPU flip them
  BottomUp := Frame.ScanLine[0] <> Frame.Data;
  if BottomUp then
    SDL_RenderTextureRotated(Renderer, Texture, nil, nil, 0, nil, SDL_FLIP_VERTICAL)
  else
    SDL_RenderTexture(Renderer, Texture, nil, nil);
  SDL_RenderPresent(Renderer);        // waits for the vertical blank (vsync)

  Inc(Frames);
  if t - FpsStart >= 1000 then
  begin
    SDL_SetWindowTitle(Window, PAnsiChar(AnsiString(Format('%s  -  %.0f fps%s',
      [AppName, Frames * 1000 / (t - FpsStart), BoolToStr(VSyncOn, ', vsync', '')]))));
    Frames := 0;
    FpsStart := t;
  end;
end;

var
  Ini: string;
  FrameStart: double;
begin
  if not SDL_Init(SDL_INIT_VIDEO) then Fail('SDL_Init');
  if not SDL_CreateWindowAndRenderer(AppName, StartW, StartH,
    SDL_WINDOW_RESIZABLE or SDL_WINDOW_HIGH_PIXEL_DENSITY, @Window, @Renderer) then
    Fail('SDL_CreateWindowAndRenderer');
  SDL_SetWindowMinimumSize(Window, 320, 180);
  VSyncOn := SDL_SetRenderVSync(Renderer, 1);

  Hex := THexBackground.Create;
  Ini := ChangeFileExt(ParamStr(0), '.ini');
  if not FileExists(Ini) then Ini := ExtractFilePath(ParamStr(0)) + 'HexFlight.ini';
  if FileExists(Ini) then Hex.LoadFromIni(Ini);
  Hex.AsyncSprites := True;           // big sprites are built in the background
  Frame := TBGRABitmap.Create(16, 16, BGRABlack);
  LastTick := NowMs;
  FpsStart := LastTick;
  try
    while Running do
    begin
      FrameStart := NowMs;
      HandleEvents;
      if not Running then Break;
      DrawFrame;
      // without vsync: about 60 frames per second, not 100 % of a core
      if not VSyncOn then
        while NowMs - FrameStart < 1000 / 60 - 1 do
          SDL_Delay(1);
    end;
  finally
    if Texture <> nil then SDL_DestroyTexture(Texture);
    Frame.Free;
    Hex.Free;
    SDL_DestroyRenderer(Renderer);
    SDL_DestroyWindow(Window);
    SDL_Quit;
  end;
end.
