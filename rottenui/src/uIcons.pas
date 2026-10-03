// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uIcons;

{$mode objfpc}{$H+}

// Icones embarquees: masques Tabler qui ne portent que la transparence, colores a
// l'execution par le theme. Les identifiants finissent dans les profils: les renommer,
// c'est casser les profils des autres sans les prevenir.

interface

uses
  Classes, SysUtils, Controls, Graphics;

{$I uIconCatalog.inc}

function IconIndex(const AId: string): Integer;
function IconCount: Integer;
function IconIdAt(AIndex: Integer): string;
function IconPixelSize(ALogical, APixelsPerInch: Integer): Integer;
function ScreenIconSize(ALogical: Integer): Integer;
function BuildIconList(AOwner: TComponent; APixelSize: Integer; AOnDark: Boolean): TImageList;
function LoadIconBitmap(const AId: string; APixelSize: Integer; AOnDark: Boolean): TBitmap;
function LoadIconTinted(const AId: string; APixelSize: Integer; AColor: TColor): TBitmap;
function IconBitmap(const AId: string; APixelSize: Integer; AColor: TColor): TBitmap;

type
  TRtIcon = class(TGraphicControl)
  private
    FIconId: string;
    FLogical: Integer;
    FIconColor: TColor;
    FTopAligned: Boolean;
    procedure SetIconColor(AValue: TColor);
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetIcon(const AId: string; ALogical: Integer; AColor: TColor);
    function PixelSize: Integer;
    property IconId: string read FIconId;
    property IconColor: TColor read FIconColor write SetIconColor;
    property TopAligned: Boolean read FTopAligned write FTopAligned;
  end;

const
  ICON_ON_DARK = TColor($D4D4D4);
  ICON_ON_LIGHT = TColor($2B2B2B);

implementation

uses
  LCLType, Forms, IntfGraphics, FPImage;

{$R rottenui_icons.res}

var
  GCache: TStringList;

function IconIndex(const AId: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(ICON_IDS) do
    if ICON_IDS[i] = AId then Exit(i);
  Result := -1;
end;

function IconCount: Integer;
begin
  Result := Length(ICON_IDS);
end;

function IconIdAt(AIndex: Integer): string;
begin
  Result := ICON_IDS[AIndex];
end;

function IconPixelSize(ALogical, APixelsPerInch: Integer): Integer;
var
  want, i: Integer;
begin
  want := (ALogical * APixelsPerInch + 48) div 96;
  for i := 0 to High(ICON_SIZES) do
    if ICON_SIZES[i] >= want then Exit(ICON_SIZES[i]);
  Result := ICON_SIZES[High(ICON_SIZES)];
end;

function ScreenIconSize(ALogical: Integer): Integer;
begin
  Result := IconPixelSize(ALogical, Screen.PixelsPerInch);
end;

function LoadIconTinted(const AId: string; APixelSize: Integer; AColor: TColor): TBitmap;
var
  rs: TResourceStream;
  png: TPortableNetworkGraphic;
  img: TLazIntfImage;
  tint, c: TFPColor;
  x, y: Integer;
begin
  Result := nil;
  if IconIndex(AId) < 0 then Exit;
  try
    rs := TResourceStream.Create(HInstance, 'ICON_' + UpperCase(StringReplace(AId, '-', '_',
      [rfReplaceAll])) + '_' + IntToStr(APixelSize), RT_RCDATA);
  except
    Exit;
  end;
  png := TPortableNetworkGraphic.Create;
  img := nil;
  try
    try
      png.LoadFromStream(rs);
      img := png.CreateIntfImage;
      tint := TColorToFPColor(ColorToRGB(AColor));
      for y := 0 to img.Height - 1 do
        for x := 0 to img.Width - 1 do
        begin
          c := img.Colors[x, y];
          tint.Alpha := c.Alpha;
          img.Colors[x, y] := tint;
        end;
      Result := TBitmap.Create;
      Result.LoadFromIntfImage(img);
    except
      FreeAndNil(Result);
    end;
  finally
    img.Free;
    png.Free;
    rs.Free;
  end;
end;

function LoadIconBitmap(const AId: string; APixelSize: Integer; AOnDark: Boolean): TBitmap;
begin
  if AOnDark then
    Result := LoadIconTinted(AId, APixelSize, ICON_ON_DARK)
  else
    Result := LoadIconTinted(AId, APixelSize, ICON_ON_LIGHT);
end;

function IconBitmap(const AId: string; APixelSize: Integer; AColor: TColor): TBitmap;
var
  key: string;
  i: Integer;
begin
  Result := nil;
  if AId = '' then Exit;
  key := AId + '|' + IntToStr(APixelSize) + '|' + IntToHex(ColorToRGB(AColor), 6);
  if GCache = nil then
  begin
    GCache := TStringList.Create;
    GCache.Sorted := True;
    GCache.OwnsObjects := True;
  end;
  i := GCache.IndexOf(key);
  if i >= 0 then Exit(TBitmap(GCache.Objects[i]));
  Result := LoadIconTinted(AId, APixelSize, AColor);
  GCache.AddObject(key, Result);
end;

function BuildIconList(AOwner: TComponent; APixelSize: Integer; AOnDark: Boolean): TImageList;
var
  i: Integer;
  bmp: TBitmap;
begin
  Result := TImageList.Create(AOwner);
  Result.Width := APixelSize;
  Result.Height := APixelSize;
  for i := 0 to High(ICON_IDS) do
  begin
    bmp := LoadIconBitmap(ICON_IDS[i], APixelSize, AOnDark);
    if bmp = nil then
    begin
      bmp := TBitmap.Create;
      bmp.SetSize(APixelSize, APixelSize);
      bmp.Transparent := True;
    end;
    try
      Result.Add(bmp, nil);
    finally
      bmp.Free;
    end;
  end;
end;

constructor TRtIcon.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLogical := 16;
  FIconColor := clWindowText;
  Width := ScreenIconSize(FLogical);
  Height := Width;
end;

function TRtIcon.PixelSize: Integer;
begin
  Result := ScreenIconSize(FLogical);
end;

procedure TRtIcon.SetIcon(const AId: string; ALogical: Integer; AColor: TColor);
begin
  FIconId := AId;
  FLogical := ALogical;
  FIconColor := AColor;
  if Align in [alNone, alLeft, alRight] then Width := PixelSize;
  if Align in [alNone, alTop, alBottom] then Height := PixelSize;
  Invalidate;
end;

procedure TRtIcon.SetIconColor(AValue: TColor);
begin
  if FIconColor = AValue then Exit;
  FIconColor := AValue;
  Invalidate;
end;

procedure TRtIcon.Paint;
var
  bmp: TBitmap;
  px, y: Integer;
begin
  px := PixelSize;
  bmp := IconBitmap(FIconId, px, FIconColor);
  if bmp = nil then Exit;
  if FTopAligned then y := 0 else y := (Height - px) div 2;
  Canvas.Draw((Width - px) div 2, y, bmp);
end;

finalization
  GCache.Free;

end.
