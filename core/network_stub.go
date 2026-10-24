//go:build !openharmony

package main

import "fmt"

func bindPhysicalSocket(fd, netID int32) error {
	return fmt.Errorf("physical socket binding requires HarmonyOS")
}
