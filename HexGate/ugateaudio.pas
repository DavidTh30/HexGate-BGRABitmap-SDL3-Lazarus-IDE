unit UGateAudio;

{ HexGate audio. Everything is synthesized in code - there are no sound
  files, so nothing can go missing and there is nothing to license.

  Output: Windows waveOut, 44.1 kHz stereo 16 bit, 4 buffers of 768 frames
  (about 70 ms) refilled by an audio thread that wakes on the driver's
  "buffer done" event.

  Music: an endless synthwave loop in A minor (Am - F - C - G, 112 BPM),
  sequenced live in 16th notes. Its layers follow Intensity (0..1):
    always       soft detuned pad + plucked arpeggio
    > 0.15       pumping saw bass
    > 0.30       kick on every beat
    > 0.55       off-beat hi-hats (16ths above 0.85)
    > 0.70       snare on 2 and 4
  Paused muffles the music (low-pass) and turns it down. Boost adds a
  rising engine hum.

  Sound effects are rendered once at start into sample buffers and mixed
  by up to 16 voices (each with its own volume and pitch). }

{$mode objfpc}{$H+}
{$Q-}{$R-}

interface

uses
  {$IFDEF WINDOWS}Windows, MMSystem,{$ENDIF}
  Classes, SysUtils, Math;

type
  TSfx = (sfxPass, sfxPerfect, sfxWhoosh, sfxCrash, sfxGameOver, sfxStart, sfxMenuMove, sfxMenuSelect);

  TGateAudio = class;

  TAudioThread = class(TThread)
  private
    FOwner: TGateAudio;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TGateAudio);
  end;

  TVoice = record
    Sfx: TSfx;
    Pos, Step, Vol: single;
    Active: boolean;
  end;

  { TGateAudio }

  TGateAudio = class
  private
    FSamples: array[TSfx] of array of single;
    FVoices: array[0..15] of TVoice;
    FLock: TRTLCriticalSection;
    FThread: TAudioThread;
    FOk: boolean;
    {$IFDEF WINDOWS}
    FWave: HWAVEOUT;
    FEvent: THandle;
    FHeaders: array[0..3] of TWaveHdr;
    FBuffers: array[0..3] of array of SmallInt;
    FNextBuf: integer;
    {$ENDIF}
    // ---- synth state, audio thread only
    FRng: cardinal;
    FSampleNo: Int64;
    FStep: Int64;
    FInt, FMusVol, FBoostAmt, FPauseAmt: single;
    FPadFreq, FPadTarget: array[0..5] of single;
    FPadPhase: array[0..5] of single;
    FPadLP: array[0..1] of single;
    FBassFreq, FBassPhase, FBassEnv, FBassLP: single;
    FArpFreq, FArpPhase, FArpEnv, FArpPan: single;
    FKickT, FKickPhase, FSnareT, FHatT, FHatLP, FSnarePhase: single;
    FHumPhase, FHumLP1, FHumLP2, FHumPitch: single;
    FMusLP: array[0..1] of single;
    function Noise: single;
    procedure BuildSamples;
    procedure SequenceStep;
    procedure Render(Buf: PSmallInt; Frames: integer);
    procedure FeedBuffers;
  public
    // set from the game thread; read by the audio thread
    MusicVolume, SfxVolume, Intensity: single;
    Boost, Paused: boolean;
    // AOpenDevice = False: no sound card, for RenderOffline (tests, export)
    constructor Create(AOpenDevice: boolean = True);
    destructor Destroy; override;
    procedure RenderOffline(Buf: PSmallInt; Frames: integer);
    procedure Play(S: TSfx; Volume: single = 1; Pitch: single = 1);
    property Ok: boolean read FOk;
  end;

implementation

const
  SR = 44100;
  BufFrames = 768;
  BPM = 112;
  // Am - F - C - G : root (MIDI) and whether the chord is minor
  ChordRoot: array[0..3] of integer = (45, 41, 48, 43);
  ChordMinor: array[0..3] of boolean = (True, False, False, False);
  ArpOrder: array[0..7] of integer = (0, 1, 2, 3, 2, 1, 3, 1);

function MidiHz(n: single): single;
begin
  Result := 440 * Power(2, (n - 69) / 12);
end;

function OnePole(var State: single; x, Cutoff: single): single; inline;
begin
  State := State + (1 - Exp(-2 * Pi * Cutoff / SR)) * (x - State);
  Result := State;
end;

function SoftClip(x: single): single; inline;
begin
  Result := x / (1 + Abs(x));
end;

{ TAudioThread }

constructor TAudioThread.Create(AOwner: TGateAudio);
begin
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(False);
  Priority := tpHigher;                // audio must never starve
end;

procedure TAudioThread.Execute;
begin
  {$IFDEF WINDOWS}
  while not Terminated do
  begin
    WaitForSingleObject(FOwner.FEvent, 20);
    if not Terminated then FOwner.FeedBuffers;
  end;
  {$ENDIF}
end;

{ TGateAudio }

constructor TGateAudio.Create(AOpenDevice: boolean);
{$IFDEF WINDOWS}
var
  Fmt: TWaveFormatEx;
  i: integer;
{$ENDIF}
begin
  InitCriticalSection(FLock);
  FRng := 2463534242;
  MusicVolume := 0.7;
  SfxVolume := 0.8;
  FPauseAmt := 0;
  BuildSamples;
  {$IFDEF WINDOWS}
  FEvent := CreateEvent(nil, False, False, nil);
  if not AOpenDevice then
  begin
    FOk := True;                         // Play works, nothing is sent to a device
    Exit;
  end;
  FillChar(Fmt, SizeOf(Fmt), 0);
  Fmt.wFormatTag := WAVE_FORMAT_PCM;
  Fmt.nChannels := 2;
  Fmt.nSamplesPerSec := SR;
  Fmt.wBitsPerSample := 16;
  Fmt.nBlockAlign := 4;
  Fmt.nAvgBytesPerSec := SR * 4;
  FOk := waveOutOpen(@FWave, WAVE_MAPPER, @Fmt, DWORD_PTR(FEvent), 0, CALLBACK_EVENT) = MMSYSERR_NOERROR;
  if not FOk then Exit;
  for i := 0 to High(FHeaders) do
  begin
    SetLength(FBuffers[i], BufFrames * 2);
    FillChar(FHeaders[i], SizeOf(TWaveHdr), 0);
    FHeaders[i].lpData := PChar(@FBuffers[i][0]);
    FHeaders[i].dwBufferLength := BufFrames * 4;
    waveOutPrepareHeader(FWave, @FHeaders[i], SizeOf(TWaveHdr));
    Render(@FBuffers[i][0], BufFrames);
    waveOutWrite(FWave, @FHeaders[i], SizeOf(TWaveHdr));
  end;
  FNextBuf := 0;
  FThread := TAudioThread.Create(Self);
  {$ENDIF}
end;

destructor TGateAudio.Destroy;
{$IFDEF WINDOWS}
var
  i: integer;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  if FThread <> nil then
  begin
    FThread.Terminate;
    SetEvent(FEvent);
    FThread.WaitFor;
    FThread.Free;
  end;
  if FOk and (FWave <> 0) then
  begin
    waveOutReset(FWave);
    for i := 0 to High(FHeaders) do
      waveOutUnprepareHeader(FWave, @FHeaders[i], SizeOf(TWaveHdr));
    waveOutClose(FWave);
  end;
  CloseHandle(FEvent);
  {$ENDIF}
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TGateAudio.FeedBuffers;
begin
  {$IFDEF WINDOWS}
  // refill the buffers in the order they were queued
  while (FHeaders[FNextBuf].dwFlags and WHDR_DONE) <> 0 do
  begin
    Render(@FBuffers[FNextBuf][0], BufFrames);
    waveOutWrite(FWave, @FHeaders[FNextBuf], SizeOf(TWaveHdr));
    FNextBuf := (FNextBuf + 1) mod Length(FHeaders);
  end;
  {$ENDIF}
end;

procedure TGateAudio.RenderOffline(Buf: PSmallInt; Frames: integer);
begin
  Render(Buf, Frames);
end;

function TGateAudio.Noise: single;
begin
  FRng := FRng xor (FRng shl 13);
  FRng := FRng xor (FRng shr 17);
  FRng := FRng xor (FRng shl 5);
  Result := FRng / 2147483648.0 - 1;
end;

procedure TGateAudio.Play(S: TSfx; Volume: single; Pitch: single);
var
  i, Best: integer;
begin
  if not FOk then Exit;
  EnterCriticalSection(FLock);
  try
    // a free voice, or else the one that has played the longest
    Best := 0;
    for i := 0 to High(FVoices) do
    begin
      if not FVoices[i].Active then
      begin
        Best := i;
        Break;
      end;
      if FVoices[i].Pos > FVoices[Best].Pos then Best := i;
    end;
    FVoices[Best].Sfx := S;
    FVoices[Best].Pos := 0;
    FVoices[Best].Step := Pitch;
    FVoices[Best].Vol := Volume;
    FVoices[Best].Active := True;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ ------------------------------------------------------------ sound effects }

procedure TGateAudio.BuildSamples;

  function Len(Sec: single): integer;
  begin
    Result := Round(Sec * SR);
  end;

  // short attack, exponential decay
  function Env(t, Attack, Decay: single): single;
  begin
    if t < 0 then Exit(0);
    Result := Min(1, t / Attack) * Exp(-t * Decay);
  end;

var
  i, n: integer;
  t, x, f, ph, lp, lp2, bp, cut, q: single;
  Notes: array[0..3] of single;
begin
  // gate passed: bright two-note chime E6 -> A6
  n := Len(0.5);
  SetLength(FSamples[sfxPass], n);
  for i := 0 to n - 1 do
  begin
    t := i / SR;
    x := (Sin(2 * Pi * 1318.5 * t) + 0.3 * Sin(4 * Pi * 1318.5 * t)) * Env(t, 0.003, 16) +
      (Sin(2 * Pi * 1760 * (t - 0.06)) + 0.3 * Sin(4 * Pi * 1760 * (t - 0.06))) * Env(t - 0.06, 0.003, 9);
    FSamples[sfxPass][i] := x * 0.32;
  end;

  // perfect: rising A major sparkle with a shimmer on top
  n := Len(0.9);
  SetLength(FSamples[sfxPerfect], n);
  Notes[0] := 880; Notes[1] := 1108.7; Notes[2] := 1318.5; Notes[3] := 1760;
  for i := 0 to n - 1 do
  begin
    t := i / SR;
    x := (2 * Abs(2 * Frac(Notes[0] * t) - 1) - 1) * Env(t, 0.002, 9);
    x := x + (2 * Abs(2 * Frac(Notes[1] * (t - 0.05)) - 1) - 1) * Env(t - 0.05, 0.002, 9);
    x := x + (2 * Abs(2 * Frac(Notes[2] * (t - 0.10)) - 1) - 1) * Env(t - 0.10, 0.002, 8);
    x := x + (2 * Abs(2 * Frac(Notes[3] * (t - 0.15)) - 1) - 1) * Env(t - 0.15, 0.002, 6);
    x := x + Sin(2 * Pi * 3520 * t) * Sin(2 * Pi * 7 * t) * Env(t - 0.15, 0.01, 5) * 0.4;
    FSamples[sfxPerfect][i] := x * 0.16;
  end;

  // whoosh: noise through a band-pass that sweeps up and down
  n := Len(0.55);
  SetLength(FSamples[sfxWhoosh], n);
  lp := 0; bp := 0;
  for i := 0 to n - 1 do
  begin
    t := i / n;
    cut := 300 + 2400 * Sin(Pi * t);
    f := 2 * Sin(Pi * cut / SR);
    q := 0.5;
    x := Noise;
    // Chamberlin state-variable filter
    lp := lp + f * bp;
    bp := bp + f * (x - lp - q * bp);
    FSamples[sfxWhoosh][i] := bp * Sqr(Sin(Pi * t)) * 0.35;
  end;

  // crash: falling noise burst, low thud, a little grit
  n := Len(1.1);
  SetLength(FSamples[sfxCrash], n);
  lp := 0; lp2 := 0; ph := 0;
  for i := 0 to n - 1 do
  begin
    t := i / SR;
    x := OnePole(lp, Noise, 150 + 5000 * Exp(-t * 6));
    x := OnePole(lp2, x, 150 + 5000 * Exp(-t * 6)) * Exp(-t * 3.5) * 1.6;
    ph := ph + (50 + 70 * Exp(-t * 18)) / SR;
    x := x + Sin(2 * Pi * ph) * Exp(-t * 5) * 0.9;
    FSamples[sfxCrash][i] := SoftClip(x * 1.5) * 0.7;
  end;

  // game over: four falling saw notes A4 F4 D4 A3, muffled
  n := Len(2.0);
  SetLength(FSamples[sfxGameOver], n);
  Notes[0] := 440; Notes[1] := 349.2; Notes[2] := 293.7; Notes[3] := 220;
  lp := 0;
  for i := 0 to n - 1 do
  begin
    t := i / SR;
    x := 0;
    if t < 0.3 then x := (2 * Frac(Notes[0] * t) - 1) * Env(t, 0.01, 4)
    else if t < 0.6 then x := (2 * Frac(Notes[1] * t) - 1) * Env(t - 0.3, 0.01, 4)
    else if t < 0.9 then x := (2 * Frac(Notes[2] * t) - 1) * Env(t - 0.6, 0.01, 4)
    else x := ((2 * Frac(Notes[3] * t) - 1) + (2 * Frac(Notes[3] * 1.005 * t) - 1)) * 0.6 * Env(t - 0.9, 0.01, 1.8);
    FSamples[sfxGameOver][i] := OnePole(lp, x, 1400) * 0.4;
  end;

  // start: rising sweep with a whoosh
  n := Len(0.7);
  SetLength(FSamples[sfxStart], n);
  ph := 0; lp := 0; bp := 0; lp2 := 0;
  for i := 0 to n - 1 do
  begin
    t := i / SR;
    ph := ph + 220 * Power(6, Min(1, t / 0.45)) / SR;
    x := (Sin(2 * Pi * ph) + 0.35 * Sign(Sin(2 * Pi * ph))) * Env(t, 0.01, 4.5);
    x := OnePole(lp, x, 3000);
    f := 2 * Sin(Pi * (400 + 3000 * Min(1, t / 0.5)) / SR);
    lp2 := lp2 + f * bp;
    bp := bp + f * (Noise - lp2 - 0.6 * bp);
    FSamples[sfxStart][i] := (x * 0.3 + bp * 0.2 * Env(t, 0.05, 5));
  end;

  // menu move: soft tick
  n := Len(0.07);
  SetLength(FSamples[sfxMenuMove], n);
  for i := 0 to n - 1 do
  begin
    t := i / SR;
    FSamples[sfxMenuMove][i] := Sin(2 * Pi * 1400 * t) * Env(t, 0.001, 60) * 0.3;
  end;

  // menu select: two-tone blip
  n := Len(0.25);
  SetLength(FSamples[sfxMenuSelect], n);
  for i := 0 to n - 1 do
  begin
    t := i / SR;
    FSamples[sfxMenuSelect][i] := (Sin(2 * Pi * 880 * t) * Env(t, 0.002, 25) +
      Sin(2 * Pi * 1320 * (t - 0.05)) * Env(t - 0.05, 0.002, 14)) * 0.3;
  end;
end;

{ -------------------------------------------------------------------- music }

// Called on every 16th note: start the notes and drums of this step.
procedure TGateAudio.SequenceStep;
var
  s16, bar, root, i: integer;
  Third: integer;
  Tones: array[0..3] of integer;
begin
  s16 := FStep mod 16;
  bar := (FStep div 16) mod 4;
  root := ChordRoot[bar];
  if ChordMinor[bar] then Third := 3 else Third := 4;
  Tones[0] := 0;
  Tones[1] := Third;
  Tones[2] := 7;
  Tones[3] := 12;

  // pad follows the chord (it glides there)
  if s16 = 0 then
    for i := 0 to 2 do
    begin
      FPadTarget[i * 2] := MidiHz(root + 12 + Tones[i]);
      FPadTarget[i * 2 + 1] := FPadTarget[i * 2] * 1.006;     // detuned twin
    end;

  // arpeggio on 8th notes, two octaves above the root
  if s16 mod 2 = 0 then
  begin
    FArpFreq := MidiHz(root + 24 + Tones[ArpOrder[(s16 div 2) mod 8]]);
    FArpEnv := 1;
    FArpPan := -FArpPan;
    if FArpPan = 0 then FArpPan := 0.5;
  end;

  // pumping bass: root, octave on the off 16ths
  if FInt > 0.15 then
  begin
    if s16 mod 2 = 1 then FBassFreq := MidiHz(root) else FBassFreq := MidiHz(root - 12);
    FBassEnv := 1;
  end;

  if (FInt > 0.30) and (s16 mod 4 = 0) then FKickT := 0;
  if (FInt > 0.70) and ((s16 = 4) or (s16 = 12)) then FSnareT := 0;
  if (FInt > 0.55) and (s16 mod 4 = 2) then FHatT := 0;
  if (FInt > 0.85) and (s16 mod 2 = 1) then FHatT := 0;
end;

procedure TGateAudio.Render(Buf: PSmallInt; Frames: integer);
var
  n, i, k, idx: integer;
  StepLen, L, R, m, x, fr, a, FxSum, Target: single;
  Smp: ^single;
begin
  StepLen := SR * 60 / BPM / 4;
  // smooth the control values once per buffer
  FInt := FInt + (EnsureRange(Intensity, 0, 1) - FInt) * 0.05;
  FMusVol := FMusVol + (EnsureRange(MusicVolume, 0, 1) - FMusVol) * 0.2;
  if Paused then Target := 1 else Target := 0;
  FPauseAmt := FPauseAmt + (Target - FPauseAmt) * 0.15;
  if FPadFreq[0] = 0 then
  begin
    FStep := -1;
    for i := 0 to 5 do FPadFreq[i] := 220;
  end;

  EnterCriticalSection(FLock);
  try
    for n := 0 to Frames - 1 do
    begin
      // ---- sequencer
      k := Floor(FSampleNo / StepLen);
      if k <> FStep then
      begin
        FStep := k;
        SequenceStep;
      end;
      Inc(FSampleNo);

      // ---- pad: 3 chord notes x 2 detuned saws, glide, soft low-pass
      L := 0;
      R := 0;
      for i := 0 to 5 do
      begin
        FPadFreq[i] := FPadFreq[i] + (FPadTarget[i] - FPadFreq[i]) * 0.0004;
        FPadPhase[i] := Frac(FPadPhase[i] + FPadFreq[i] / SR);
        x := 2 * FPadPhase[i] - 1;
        if Odd(i) then R := R + x else L := L + x;
      end;
      fr := 700 + 900 * FInt;
      L := OnePole(FPadLP[0], L, fr) * 0.06;
      R := OnePole(FPadLP[1], R, fr) * 0.06;

      // ---- arpeggio: plucked triangle, ping-pong pan
      FArpPhase := Frac(FArpPhase + FArpFreq / SR);
      FArpEnv := FArpEnv * 0.99984;
      x := (2 * Abs(2 * FArpPhase - 1) - 1) * FArpEnv * FArpEnv * (0.065 + 0.03 * FInt);
      L := L + x * (0.5 - FArpPan * 0.5);
      R := R + x * (0.5 + FArpPan * 0.5);

      // ---- bass: saw + square through an envelope-driven low-pass
      if FInt > 0.15 then
      begin
        FBassPhase := Frac(FBassPhase + FBassFreq / SR);
        FBassEnv := FBassEnv * 0.99975;
        x := (2 * FBassPhase - 1) * 0.7 + Sign(0.5 - FBassPhase) * 0.3;
        x := OnePole(FBassLP, x, 150 + 1600 * FBassEnv * FBassEnv) * (0.25 + 0.75 * FBassEnv);
        m := x * 0.20 * EnsureRange((FInt - 0.15) * 4, 0, 1);
        L := L + m;
        R := R + m;
      end;

      // ---- kick: falling sine
      if FKickT < 0.5 then
      begin
        FKickPhase := Frac(FKickPhase + (45 + 95 * Exp(-FKickT * 30)) / SR);
        m := Sin(2 * Pi * FKickPhase) * Exp(-FKickT * 9) * 0.42;
        L := L + m;
        R := R + m;
        FKickT := FKickT + 1 / SR;
      end;

      // ---- snare: noise + body tone
      if FSnareT < 0.3 then
      begin
        FSnarePhase := Frac(FSnarePhase + 185 / SR);
        m := (Noise * 0.55 * Exp(-FSnareT * 20) + Sin(2 * Pi * FSnarePhase) * 0.35 * Exp(-FSnareT * 28)) * 0.22;
        L := L + m;
        R := R + m;
        FSnareT := FSnareT + 1 / SR;
      end;

      // ---- hi-hat: high-passed noise tick
      if FHatT < 0.08 then
      begin
        x := Noise;
        m := (x - OnePole(FHatLP, x, 6000)) * Exp(-FHatT * 70) * 0.10;
        L := L + m * 0.8;
        R := R + m;
        FHatT := FHatT + 1 / SR;
      end;

      // ---- pause: muffle and duck the music
      fr := 18000 - 17300 * FPauseAmt;
      L := OnePole(FMusLP[0], L, fr) * FMusVol * (1 - 0.5 * FPauseAmt);
      R := OnePole(FMusLP[1], R, fr) * FMusVol * (1 - 0.5 * FPauseAmt);

      // ---- boost: engine hum rising in pitch
      if Boost then Target := 1 else Target := 0;
      FBoostAmt := FBoostAmt + (Target - FBoostAmt) * 0.0004;
      if FBoostAmt > 0.002 then
      begin
        FHumPitch := FHumPitch + ((55 + 40 * FBoostAmt) - FHumPitch) * 0.0002;
        FHumPhase := Frac(FHumPhase + FHumPitch / SR);
        x := OnePole(FHumLP1, Noise, 900 + 1500 * FBoostAmt);
        x := x - OnePole(FHumLP2, x, 250);
        m := (x * 0.5 + (2 * FHumPhase - 1) * 0.12) * FBoostAmt * 0.35 * EnsureRange(SfxVolume, 0, 1);
        L := L + m;
        R := R + m;
      end;

      // ---- sound effects
      FxSum := 0;
      for i := 0 to High(FVoices) do
        with FVoices[i] do
          if Active then
          begin
            idx := Trunc(Pos);
            if idx >= High(FSamples[Sfx]) then
            begin
              Active := False;
              Continue;
            end;
            Smp := @FSamples[Sfx][idx];
            a := Pos - idx;
            FxSum := FxSum + (Smp^ + ((Smp + 1)^ - Smp^) * a) * Vol;
            Pos := Pos + Step;
          end;
      FxSum := FxSum * EnsureRange(SfxVolume, 0, 1);

      // master gain into a soft limiter: loud, never harsh clipping
      L := SoftClip((L + FxSum) * 1.7);
      R := SoftClip((R + FxSum) * 1.7);
      Buf^ := Round(L * 32000);
      Inc(Buf);
      Buf^ := Round(R * 32000);
      Inc(Buf);
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.
