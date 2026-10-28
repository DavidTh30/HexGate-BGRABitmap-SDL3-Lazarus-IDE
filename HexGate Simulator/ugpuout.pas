unit UGpuOut;

{ GPU output for HexGate (SDL3).

  The engine (THexBackground.BuildFrame) still decides everything on the CPU:
  camera, depth, blur, sprite choice and the far-to-near draw list. This
  unit only replaces the CPU pixel blending of that list (the expensive
  part, 15-20 ms on 12 threads) with GPU draws through the SDL renderer:

    background   texture, re-uploaded only when the engine makes a new one
    ckBlit       each cached sprite is uploaded once as a texture (premultiplied
                 alpha, linear filtering) and drawn as a quad at its exact
                 sub-pixel position and size; opacity via colour + alpha mod
    ckLine       a coloured quad (SDL_RenderGeometry)
    ckDisc       one soft white disc texture, tinted per spark
    vignette     texture over everything
    HUD          drawn by the game into a transparent bitmap, uploaded and
                 drawn on top

  Everything is drawn in frame coordinates (the engine's render size); the
  render scale maps them onto the window, so the GPU also does the
  stretching. Sprite textures are released through SpriteFreeHook when the
  engine frees a sprite.

  Simulator addition - ATLAS mode (UseAtlas): sprites are cut from one
  pre-baked atlas texture (from a hexgate-graphics file) instead of the
  engine's own sprites, and the background / vignette come from the file's
  images. The draw list is the same; only the pictures differ. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, SDL3, BGRABitmap, BGRABitmapTypes, UHexBackground;

type
  // atlas rectangle (X, Y, W x W) of the sprite closest to (Kind, on-screen
  // radius R, on-screen blur); Rq = the radius that sprite was drawn at
  TAtlasLookup = function(Kind: integer; R, Blur: single; out X, Y, W: integer;
    out Rq: single): boolean of object;

  { TGpuOut }

  TGpuOut = class
  private
    FRen: PSDL_Renderer;
    FBase, FVig, FHud, FDisc: PSDL_Texture;
    FBaseGen, FBaseW, FBaseH, FHudW, FHudH: integer;
    FBaseSrc: TBGRABitmap;
    FBaseFlip, FVigFlip, FHudFlip: boolean;
    FDraws: integer;
    FAtlasTex, FFileBase, FFileVig: PSDL_Texture;
    FFileBaseFlip, FFileVigFlip, FAtlasFlip: boolean;
    FUseAtlas: boolean;
    FLookup: TAtlasLookup;
    procedure Upload(var Tex: PSDL_Texture; Bmp: TBGRABitmap; Blend: TSDL_BlendMode;
      Access: TSDL_TextureAccess; out Flip: boolean);
    procedure DrawFull(Tex: PSDL_Texture; Flip: boolean; W, H: integer);
    function SpriteTexture(Spr: TSprite): PSDL_Texture;
  public
    constructor Create(ARenderer: PSDL_Renderer);
    destructor Destroy; override;
    // Draws the frame built by Hex.BuildFrame(FW, FH, ...) plus the HUD
    // (FW x FH, transparent where empty) over the whole output. Does not present.
    procedure Draw(Hex: THexBackground; FW, FH: integer; Hud: TBGRABitmap);
    property DrawCalls: integer read FDraws;
    // atlas premultiplied; Base / Vig straight alpha (any of them may be nil)
    procedure SetAtlasImages(Atlas, Base, Vig: TBGRABitmap);
    property UseAtlas: boolean read FUseAtlas write FUseAtlas;
    property Lookup: TAtlasLookup read FLookup write FLookup;
  end;

implementation

const
  DiscSize = 64;

procedure FreeSpriteTexture(Spr: TSprite);
begin
  SDL_DestroyTexture(PSDL_Texture(Spr.Handle));
  Spr.Handle := nil;
end;

{ TGpuOut }

constructor TGpuOut.Create(ARenderer: PSDL_Renderer);
var
  Pix: array of TBGRAPixel;
  x, y, a: integer;
  d: single;
begin
  FRen := ARenderer;
  SpriteFreeHook := @FreeSpriteTexture;
  FBaseGen := -1;
  // a soft white disc (premultiplied) for the sparks
  SetLength(Pix, DiscSize * DiscSize);
  for y := 0 to DiscSize - 1 do
    for x := 0 to DiscSize - 1 do
    begin
      d := Sqrt(Sqr(x + 0.5 - DiscSize / 2) + Sqr(y + 0.5 - DiscSize / 2));
      a := EnsureRange(Round((DiscSize / 2 - 0.5 - d) * 255), 0, 255);
      Pix[y * DiscSize + x] := BGRA(a, a, a, a);
    end;
  FDisc := SDL_CreateTexture(FRen, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STATIC, DiscSize, DiscSize);
  SDL_UpdateTexture(FDisc, nil, @Pix[0], DiscSize * SizeOf(TBGRAPixel));
  SDL_SetTextureBlendMode(FDisc, SDL_BLENDMODE_BLEND_PREMULTIPLIED);
  SDL_SetTextureScaleMode(FDisc, SDL_SCALEMODE_LINEAR);
end;

destructor TGpuOut.Destroy;
begin
  // sprites still alive keep their textures until the renderer goes away
  SpriteFreeHook := nil;
  if FBase <> nil then SDL_DestroyTexture(FBase);
  if FVig <> nil then SDL_DestroyTexture(FVig);
  if FHud <> nil then SDL_DestroyTexture(FHud);
  if FDisc <> nil then SDL_DestroyTexture(FDisc);
  if FAtlasTex <> nil then SDL_DestroyTexture(FAtlasTex);
  if FFileBase <> nil then SDL_DestroyTexture(FFileBase);
  if FFileVig <> nil then SDL_DestroyTexture(FFileVig);
  inherited Destroy;
end;

// Copy a whole bitmap into a texture of the same size (re-created if needed).
procedure TGpuOut.Upload(var Tex: PSDL_Texture; Bmp: TBGRABitmap; Blend: TSDL_BlendMode;
  Access: TSDL_TextureAccess; out Flip: boolean);
var
  tw, th: single;
begin
  tw := 0;
  th := 0;
  if Tex <> nil then SDL_GetTextureSize(Tex, @tw, @th);
  if (Tex = nil) or (Round(tw) <> Bmp.Width) or (Round(th) <> Bmp.Height) then
  begin
    if Tex <> nil then SDL_DestroyTexture(Tex);
    Tex := SDL_CreateTexture(FRen, SDL_PIXELFORMAT_ARGB8888, Access, Bmp.Width, Bmp.Height);
    SDL_SetTextureBlendMode(Tex, Blend);
    SDL_SetTextureScaleMode(Tex, SDL_SCALEMODE_LINEAR);
  end;
  SDL_UpdateTexture(Tex, nil, Bmp.Data, Bmp.Width * SizeOf(TBGRAPixel));
  // some BGRABitmap builds store the rows bottom-up
  Flip := Bmp.ScanLine[0] <> Bmp.Data;
end;

procedure TGpuOut.DrawFull(Tex: PSDL_Texture; Flip: boolean; W, H: integer);
var
  Dst: TSDL_FRect;
begin
  Dst.x := 0;
  Dst.y := 0;
  Dst.w := W;
  Dst.h := H;
  if Flip then
    SDL_RenderTextureRotated(FRen, Tex, nil, @Dst, 0, nil, SDL_FLIP_VERTICAL)
  else
    SDL_RenderTexture(FRen, Tex, nil, @Dst);
  Inc(FDraws);
end;

procedure TGpuOut.SetAtlasImages(Atlas, Base, Vig: TBGRABitmap);
begin
  if Atlas <> nil then
  begin
    Upload(FAtlasTex, Atlas, SDL_BLENDMODE_BLEND_PREMULTIPLIED, SDL_TEXTUREACCESS_STATIC, FAtlasFlip);
    // rectangles are measured from the top: keep rows top-down
    if FAtlasFlip then
    begin
      Atlas.VerticalFlip;
      Upload(FAtlasTex, Atlas, SDL_BLENDMODE_BLEND_PREMULTIPLIED, SDL_TEXTUREACCESS_STATIC, FAtlasFlip);
      Atlas.VerticalFlip;
    end;
  end;
  if Base <> nil then Upload(FFileBase, Base, SDL_BLENDMODE_NONE, SDL_TEXTUREACCESS_STATIC, FFileBaseFlip);
  if Vig <> nil then Upload(FFileVig, Vig, SDL_BLENDMODE_BLEND, SDL_TEXTUREACCESS_STATIC, FFileVigFlip);
end;

function TGpuOut.SpriteTexture(Spr: TSprite): PSDL_Texture;
begin
  if Spr.Handle = nil then
  begin
    // sprites are premultiplied B, G, R, A rows, top-down
    Result := SDL_CreateTexture(FRen, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STATIC, Spr.W, Spr.W);
    if Result = nil then Exit;
    SDL_UpdateTexture(Result, nil, @Spr.Pix[0], Spr.W * SizeOf(TBGRAPixel));
    SDL_SetTextureBlendMode(Result, SDL_BLENDMODE_BLEND_PREMULTIPLIED);
    SDL_SetTextureScaleMode(Result, SDL_SCALEMODE_LINEAR);
    Spr.Handle := Result;
  end;
  Result := PSDL_Texture(Spr.Handle);
end;

procedure TGpuOut.Draw(Hex: THexBackground; FW, FH: integer; Hud: TBGRABitmap);
var
  OutW, OutH, i: integer;
  C: PDrawCmd;
  T: PSDL_Texture;
  Dst: TSDL_FRect;
  o, half, dx, dy, len, nx, ny, a, sz, rq: single;
  Src: TSDL_FRect;
  ax, ay, aw: integer;
  Atl: boolean;
  V: array[0..3] of TSDL_Vertex;
  Col: TSDL_FColor;
const
  Quad: array[0..5] of longint = (0, 1, 2, 0, 2, 3);
begin
  FDraws := 0;
  OutW := 0;
  OutH := 0;
  SDL_GetRenderOutputSize(FRen, @OutW, @OutH);
  // frame coordinates -> window pixels: the GPU does the stretching
  SDL_SetRenderScale(FRen, Max(1, OutW) / FW, Max(1, OutH) / FH);
  SDL_SetRenderDrawBlendMode(FRen, SDL_BLENDMODE_BLEND);

  Atl := FUseAtlas and (FAtlasTex <> nil) and Assigned(FLookup);

  // ---- background
  if Hex.JobBase and FUseAtlas and (FFileBase <> nil) then
    DrawFull(FFileBase, FFileBaseFlip, FW, FH)
  else if Hex.JobBase then
  begin
    if (Hex.ScreenGen <> FBaseGen) or (Hex.FrameBase <> FBaseSrc) or
      (Hex.FrameBase.Width <> FBaseW) or (Hex.FrameBase.Height <> FBaseH) then
    begin
      Upload(FBase, Hex.FrameBase, SDL_BLENDMODE_NONE, SDL_TEXTUREACCESS_STATIC, FBaseFlip);
      Upload(FVig, Hex.FrameVignette, SDL_BLENDMODE_BLEND, SDL_TEXTUREACCESS_STATIC, FVigFlip);
      FBaseGen := Hex.ScreenGen;
      FBaseSrc := Hex.FrameBase;
      FBaseW := FBaseSrc.Width;
      FBaseH := FBaseSrc.Height;
    end;
    DrawFull(FBase, FBaseFlip, FW, FH);
  end
  else
  begin
    SDL_SetRenderDrawColor(FRen, 0, 0, 0, 255);
    SDL_RenderClear(FRen);
  end;

  // ---- the draw list, far to near
  for i := 0 to Hex.CmdCount - 1 do
  begin
    C := Hex.Cmd(i);
    case C^.Kind of
      ckBlit:
        if Atl then
        begin
          // ATLAS mode: the closest pre-baked sprite, scaled to the real size
          sz := C^.Spr.Rq * C^.S;               // on-screen radius
          if not FLookup(C^.Spr.Kind, sz, C^.Spr.Bq * C^.S, ax, ay, aw, rq) then Continue;
          o := EnsureRange(C^.A, 0, 1);
          SDL_SetTextureColorModFloat(FAtlasTex, o, o, o);
          SDL_SetTextureAlphaModFloat(FAtlasTex, o);
          Src.x := ax;
          Src.y := ay;
          Src.w := aw;
          Src.h := aw;
          sz := aw * sz / rq;
          Dst.x := C^.X + 0.5 - sz / 2;
          Dst.y := C^.Y + 0.5 - sz / 2;
          Dst.w := sz;
          Dst.h := sz;
          SDL_RenderTexture(FRen, FAtlasTex, @Src, @Dst);
          Inc(FDraws);
        end
        else
        begin
          T := SpriteTexture(C^.Spr);
          if T = nil then Continue;
          o := EnsureRange(C^.A, 0, 1);
          // premultiplied: the colour has to fade with the alpha
          SDL_SetTextureColorModFloat(T, o, o, o);
          SDL_SetTextureAlphaModFloat(T, o);
          // texel centres line up with the CPU blitter's mapping
          sz := C^.Spr.W * C^.S;
          half := sz / 2;
          Dst.x := C^.X + 0.5 - half;
          Dst.y := C^.Y + 0.5 - half;
          Dst.w := sz;
          Dst.h := sz;
          SDL_RenderTexture(FRen, T, nil, @Dst);
          Inc(FDraws);
        end;
      ckLine:
        begin
          if C^.CA <= 0 then Continue;
          dx := C^.X2 - C^.X;
          dy := C^.Y2 - C^.Y;
          len := Sqrt(dx * dx + dy * dy);
          if len < 0.01 then Continue;
          // a quad around the segment, as wide as the line
          nx := -dy / len * Max(0.5, C^.HW);
          ny := dx / len * Max(0.5, C^.HW);
          a := C^.CA / 255;
          Col.r := C^.CR / C^.CA;     // the command stores premultiplied colour
          Col.g := C^.CG / C^.CA;
          Col.b := C^.CB / C^.CA;
          Col.a := a;
          V[0].position.x := C^.X + 0.5 + nx;   V[0].position.y := C^.Y + 0.5 + ny;
          V[1].position.x := C^.X2 + 0.5 + nx;  V[1].position.y := C^.Y2 + 0.5 + ny;
          V[2].position.x := C^.X2 + 0.5 - nx;  V[2].position.y := C^.Y2 + 0.5 - ny;
          V[3].position.x := C^.X + 0.5 - nx;   V[3].position.y := C^.Y + 0.5 - ny;
          V[0].color := Col; V[1].color := Col; V[2].color := Col; V[3].color := Col;
          V[0].tex_coord.x := 0; V[0].tex_coord.y := 0;
          V[1].tex_coord := V[0].tex_coord; V[2].tex_coord := V[0].tex_coord; V[3].tex_coord := V[0].tex_coord;
          SDL_RenderGeometry(FRen, nil, @V[0], 4, @Quad[0], 6);
          Inc(FDraws);
        end;
      ckDisc:
        begin
          // tinted soft disc; the disc texture's edge sits half a texel inside
          SDL_SetTextureColorModFloat(FDisc, C^.CR / 255, C^.CG / 255, C^.CB / 255);
          SDL_SetTextureAlphaModFloat(FDisc, C^.CA / 255);
          sz := (C^.S + 0.5) * 2 * DiscSize / (DiscSize - 1);
          Dst.x := C^.X + 0.5 - sz / 2;
          Dst.y := C^.Y + 0.5 - sz / 2;
          Dst.w := sz;
          Dst.h := sz;
          SDL_RenderTexture(FRen, FDisc, nil, @Dst);
          Inc(FDraws);
        end;
    end;
  end;

  // ---- vignette and HUD on top
  if Hex.JobVig and FUseAtlas and (FFileVig <> nil) then
    DrawFull(FFileVig, FFileVigFlip, FW, FH)
  else if Hex.JobVig and (FVig <> nil) then
    DrawFull(FVig, FVigFlip, FW, FH);
  if Hud <> nil then
  begin
    Upload(FHud, Hud, SDL_BLENDMODE_BLEND, SDL_TEXTUREACCESS_STREAMING, FHudFlip);
    DrawFull(FHud, FHudFlip, FW, FH);
  end;
  SDL_SetRenderScale(FRen, 1, 1);
end;

end.
