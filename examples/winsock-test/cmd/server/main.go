package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/JBUinfo/steamos-xdbg-launcher/examples/winsock-test/internal/winsock"
)

func main() {
	port := flag.Int("port", 27015, "TCP port to listen on localhost")
	once := flag.Bool("once", false, "serve one client and exit")
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

	listener, err := winsock.Socket()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer winsock.Close(listener)

	address := winsock.Address(127, 0, 0, 1, uint16(*port))
	if err := winsock.Bind(listener, &address); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := winsock.Listen(listener, 8); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	fmt.Printf("winsock server listening on 127.0.0.1:%d (pid %d)\n", *port, os.Getpid())
	for {
		connection, err := winsock.Accept(listener)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}

		buffer := make([]byte, 256)
		count, receiveErr := winsock.Recv(connection, buffer)
		if receiveErr != nil {
			fmt.Fprintln(os.Stderr, receiveErr)
			_ = winsock.Close(connection)
			os.Exit(1)
		}
		fmt.Printf("received %d bytes: %q\n", count, buffer[:count])
		if _, sendErr := winsock.Send(connection, []byte("pong from winsock server\n")); sendErr != nil {
			fmt.Fprintln(os.Stderr, sendErr)
			_ = winsock.Close(connection)
			os.Exit(1)
		}
		_ = winsock.Close(connection)
		if *once {
			return
		}
	}
}
