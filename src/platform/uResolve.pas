// Copyright (C) 2023-2026 Cyril LAMY
// SPDX-License-Identifier: GPL-3.0-or-later
unit uResolve;

{$mode objfpc}{$H+}

// Resolution de nom par getaddrinfo, pour l'etape "resolution" du test de connexion.
// libldap resout a nouveau de son cote: ce resultat informe, il ne choisit pas
// l'adresse contactee.

interface

uses
  SysUtils;

type
  TResolveResult = record
    Ok: Boolean;
    Addresses: array of string;
    Error: string;
  end;

function ResolveHost(const AHost: string): TResolveResult;

implementation

uses
  ctypes{$IFDEF WINDOWS}, Windows{$ENDIF};

const
  NI_MAXHOST = 1025;
  NI_NUMERICHOST = {$IFDEF WINDOWS}$02{$ELSE}1{$ENDIF};

type
  PAddrInfo = ^TAddrInfo;
  {$IF DEFINED(WINDOWS)}
  TAddrInfo = record
    ai_flags: cint;
    ai_family: cint;
    ai_socktype: cint;
    ai_protocol: cint;
    ai_addrlen: csize_t;
    ai_canonname: PAnsiChar;
    ai_addr: Pointer;
    ai_next: PAddrInfo;
  end;
  {$ELSEIF DEFINED(DARWIN) OR DEFINED(BSD)}
  // netdb.h BSD/macOS: ai_canonname precede ai_addr, l'ordre inverse de glibc.
  TAddrInfo = record
    ai_flags: cint;
    ai_family: cint;
    ai_socktype: cint;
    ai_protocol: cint;
    ai_addrlen: cuint32;
    ai_canonname: PAnsiChar;
    ai_addr: Pointer;
    ai_next: PAddrInfo;
  end;
  {$ELSE}
  // glibc et musl: ai_addr precede ai_canonname.
  TAddrInfo = record
    ai_flags: cint;
    ai_family: cint;
    ai_socktype: cint;
    ai_protocol: cint;
    ai_addrlen: cuint32;
    ai_addr: Pointer;
    ai_canonname: PAnsiChar;
    ai_next: PAddrInfo;
  end;
  {$ENDIF}

{$IFDEF WINDOWS}
type
  TWSAData = record
    wVersion: Word;
    wHighVersion: Word;
    reserved: array[0..511] of Byte;
  end;

function WSAStartup(wVersionRequired: Word; var lpWSAData: TWSAData): cint; stdcall; external 'ws2_32.dll';
function getaddrinfo(nodename, servname: PAnsiChar; hints: PAddrInfo; res: PPointer): cint; stdcall; external 'ws2_32.dll';
procedure freeaddrinfo(ai: PAddrInfo); stdcall; external 'ws2_32.dll';
function getnameinfo(sa: Pointer; salen: cint; host: PAnsiChar; hostlen: DWORD;
  serv: PAnsiChar; servlen: DWORD; flags: cint): cint; stdcall; external 'ws2_32.dll';
{$ELSE}
function getaddrinfo(nodename, servname: PAnsiChar; hints: PAddrInfo; res: PPointer): cint; cdecl; external 'c';
procedure freeaddrinfo(ai: PAddrInfo); cdecl; external 'c';
function getnameinfo(sa: Pointer; salen: cuint32; host: PAnsiChar; hostlen: cuint32;
  serv: PAnsiChar; servlen: cuint32; flags: cint): cint; cdecl; external 'c';
function gai_strerror(errcode: cint): PAnsiChar; cdecl; external 'c';
{$ENDIF}

{$IFDEF WINDOWS}
var
  GWsaReady: Boolean = False;
{$ENDIF}

function ResolveHost(const AHost: string): TResolveResult;
var
  hints: TAddrInfo;
  res, cur: PAddrInfo;
  rc, i: cint;
  buf: array[0..NI_MAXHOST] of AnsiChar;
  txt: string;
  dup: Boolean;
  {$IFDEF WINDOWS}
  wsa: TWSAData;
  {$ENDIF}
begin
  Result := Default(TResolveResult);
  {$IFDEF WINDOWS}
  if not GWsaReady then
    GWsaReady := WSAStartup($0202, wsa) = 0;
  {$ENDIF}
  FillChar(hints, SizeOf(hints), 0);
  hints.ai_socktype := 1;  // SOCK_STREAM
  res := nil;
  rc := getaddrinfo(PAnsiChar(AnsiString(AHost)), nil, @hints, @res);
  if rc <> 0 then
  begin
    {$IFDEF WINDOWS}
    Result.Error := Format('name resolution failed (%d)', [rc]);
    {$ELSE}
    Result.Error := 'name resolution failed: ' + string(gai_strerror(rc));
    {$ENDIF}
    Exit;
  end;
  try
    cur := res;
    while cur <> nil do
    begin
      FillChar(buf, SizeOf(buf), 0);
      if getnameinfo(cur^.ai_addr, cur^.ai_addrlen, @buf[0], NI_MAXHOST, nil, 0,
          NI_NUMERICHOST) = 0 then
      begin
        txt := string(PAnsiChar(@buf[0]));
        dup := False;
        for i := 0 to High(Result.Addresses) do
          if Result.Addresses[i] = txt then dup := True;
        if not dup then
        begin
          SetLength(Result.Addresses, Length(Result.Addresses) + 1);
          Result.Addresses[High(Result.Addresses)] := txt;
        end;
      end;
      cur := cur^.ai_next;
    end;
  finally
    freeaddrinfo(res);
  end;
  Result.Ok := Length(Result.Addresses) > 0;
  if not Result.Ok then
    Result.Error := 'no address returned';
end;

end.
