program HexGateEditor;

{ HexGate Editor - opens, edits and saves "hexgate-graphics" files (written by
  HexGate / HexGate SDL3 with F9 or --export-graphics) and simulates them with
  the same graphics system as HexGate: the BGRABitmap renderer on all CPU
  cores, shown through OpenGL with vsync.

    uhexbackground.pas  the HexGate renderer (same engine as HexGate)
    ugfxfile.pas        reads / writes the file
    ugfxbake.pas        re-bakes the file's atlas, screen layers and reference frame
    ueditmain.pas       window: picture, edit panel, menus, autopilot

  Usage: HexGateEditor [file.json]   (default: hexgate_graphics.json next to it) }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, UHexBackground, UGfxBake, UGfxFile, UEditMain;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'HexGate Editor';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TEditorForm, EditorForm);
  Application.Run;
end.
