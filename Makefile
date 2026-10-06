.PHONY: test lint

test:
	bats tests/

lint:
	shellcheck core/*/*.sh tests/*.bats tests/__mocks__/*
