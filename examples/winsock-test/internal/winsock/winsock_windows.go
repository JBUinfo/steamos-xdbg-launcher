//go:build windows

// Package winsock contains the small, deliberately direct WinSock surface used
// by the xdbg test programs. It calls Ws2_32.dll instead of Go's net package so
// the relevant API calls are easy to find and breakpoint in x32dbg/x64dbg.
package winsock

import (
	"fmt"
	"syscall"
	"unsafe"
)

const (
	AFInet        = 2
	SockStream    = 1
	IPProtoTCP    = 6
	InvalidSocket = ^uintptr(0)
)

// SockaddrIn matches the Windows sockaddr_in layout (16 bytes).
type SockaddrIn struct {
	Family uint16
	Port   uint16
	Addr   uint32
	Zero   [8]byte
}

var (
	ws2_32       = syscall.NewLazyDLL("Ws2_32.dll")
	procWSAStart = ws2_32.NewProc("WSAStartup")
	procWSAClean = ws2_32.NewProc("WSACleanup")
	procWSAError = ws2_32.NewProc("WSAGetLastError")
	procSocket   = ws2_32.NewProc("socket")
	procBind     = ws2_32.NewProc("bind")
	procListen   = ws2_32.NewProc("listen")
	procAccept   = ws2_32.NewProc("accept")
	procConnect  = ws2_32.NewProc("connect")
	procSend     = ws2_32.NewProc("send")
	procRecv     = ws2_32.NewProc("recv")
	procClose    = ws2_32.NewProc("closesocket")
)

// Startup initializes the Winsock 2.2 library.
func Startup() error {
	var data [512]byte // large enough for WSADATA on 32-bit and 64-bit Windows
	result, _, _ := procWSAStart.Call(0x0202, uintptr(unsafe.Pointer(&data[0])))
	if result != 0 {
		return fmt.Errorf("WSAStartup failed: %d", result)
	}
	return nil
}

// Cleanup releases the Winsock library for this process.
func Cleanup() {
	_, _, _ = procWSAClean.Call()
}

func LastError() uint32 {
	result, _, _ := procWSAError.Call()
	return uint32(result)
}

func winError(operation string) error {
	return fmt.Errorf("%s failed: WSA error %d", operation, LastError())
}

// Socket creates an IPv4 TCP socket.
func Socket() (uintptr, error) {
	result, _, _ := procSocket.Call(AFInet, SockStream, IPProtoTCP)
	if result == InvalidSocket {
		return 0, winError("socket")
	}
	return result, nil
}

func Bind(socket uintptr, address *SockaddrIn) error {
	result, _, _ := procBind.Call(socket, uintptr(unsafe.Pointer(address)), uintptr(unsafe.Sizeof(*address)))
	if int32(result) == -1 {
		return winError("bind")
	}
	return nil
}

func Listen(socket uintptr, backlog int) error {
	result, _, _ := procListen.Call(socket, uintptr(backlog))
	if int32(result) == -1 {
		return winError("listen")
	}
	return nil
}

func Accept(socket uintptr) (uintptr, error) {
	result, _, _ := procAccept.Call(socket, 0, 0)
	if result == InvalidSocket {
		return 0, winError("accept")
	}
	return result, nil
}

func Connect(socket uintptr, address *SockaddrIn) error {
	result, _, _ := procConnect.Call(socket, uintptr(unsafe.Pointer(address)), uintptr(unsafe.Sizeof(*address)))
	if int32(result) == -1 {
		return winError("connect")
	}
	return nil
}

func Send(socket uintptr, data []byte) (int, error) {
	if len(data) == 0 {
		return 0, nil
	}
	result, _, _ := procSend.Call(socket, uintptr(unsafe.Pointer(&data[0])), uintptr(len(data)), 0)
	if int32(result) == -1 {
		return 0, winError("send")
	}
	return int(int32(result)), nil
}

func Recv(socket uintptr, data []byte) (int, error) {
	if len(data) == 0 {
		return 0, nil
	}
	result, _, _ := procRecv.Call(socket, uintptr(unsafe.Pointer(&data[0])), uintptr(len(data)), 0)
	if int32(result) == -1 {
		return 0, winError("recv")
	}
	return int(int32(result)), nil
}

func Close(socket uintptr) error {
	result, _, _ := procClose.Call(socket)
	if int32(result) == -1 {
		return winError("closesocket")
	}
	return nil
}

// IPv4 returns the little-endian uint32 representation expected in sockaddr_in.
func IPv4(a, b, c, d byte) uint32 {
	return uint32(a) | uint32(b)<<8 | uint32(c)<<16 | uint32(d)<<24
}

// Port converts a host-order port to the network-order representation used by
// sockaddr_in on Windows.
func Port(port uint16) uint16 {
	return port<<8 | port>>8
}

func Address(a, b, c, d byte, port uint16) SockaddrIn {
	return SockaddrIn{Family: AFInet, Port: Port(port), Addr: IPv4(a, b, c, d)}
}
