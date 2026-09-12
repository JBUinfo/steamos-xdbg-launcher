package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/JBUinfo/steamos-xdbg-launcher/examples/winsock-test/internal/winsock"
)

func main() {
	port := flag.Int("port", 27015, "TCP port on localhost")
	message := flag.String("message", "ping from winsock client\n", "message to send")
	flag.Parse()
	if *port < 1 || *port > 65535 {
		fmt.Fprintln(os.Stderr, "port must be between 1 and 65535")
		os.Exit(2)
	}

	if err := winsock.Startup(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer winsock.Cleanup()

	socket, err := winsock.Socket()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer winsock.Close(socket)

	address := winsock.Address(127, 0, 0, 1, uint16(*port))
	if err := winsock.Connect(socket, &address); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if _, err := winsock.Send(socket, []byte(*message)); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	buffer := make([]byte, 256)
	count, err := winsock.Recv(socket, buffer)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("received %d bytes: %q\n", count, buffer[:count])
}
