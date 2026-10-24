package main

import "testing"

func TestNativeInterfaceSnapshot(t *testing.T) {
	interfaces, err := nativeInterfaces()
	if err != nil {
		t.Fatal(err)
	}
	if len(interfaces) == 0 {
		t.Fatal("no interfaces")
	}
	names := map[string]bool{}
	for _, it := range interfaces {
		if names[it.Name] {
			t.Fatalf("duplicate interface %s", it.Name)
		}
		names[it.Name] = true
		if it.Index <= 0 || it.MTU <= 0 {
			t.Fatalf("invalid metadata for %s", it.Name)
		}
	}
}
