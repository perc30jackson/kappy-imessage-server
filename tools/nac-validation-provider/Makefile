BIN := kappy-nac-validation-provider
ARC_OBJS := main.o nac_wrapper.o nac_scan.o nac_validate.o nac_pac.o
MRC_OBJS := meow_memory.o nac_proxy.o
OBJS := $(ARC_OBJS) $(MRC_OBJS)
ARC_FLAGS := -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=15.0
MRC_FLAGS := -fno-objc-arc -O2 -Wall -Wextra -mmacosx-version-min=15.0
LDFLAGS := -framework Foundation -framework Security -mmacosx-version-min=15.0

$(BIN): $(OBJS)
	clang $(ARC_FLAGS) $(LDFLAGS) -o $@ $(OBJS)

main.o: main.m offsets.h nac_scan.h nac_validate.h
	clang $(ARC_FLAGS) -c main.m -o $@

nac_wrapper.o: nac_wrapper.m offsets.h meow_memory.h nac_proxy.h
	clang $(ARC_FLAGS) -c nac_wrapper.m -o $@

nac_scan.o: nac_scan.m offsets.h nac_scan.h meow_memory.h nac_proxy.h
	clang $(ARC_FLAGS) -c nac_scan.m -o $@

nac_validate.o: nac_validate.m offsets.h nac_validate.h
	clang $(ARC_FLAGS) -c nac_validate.m -o $@

nac_pac.o: nac_pac.m nac_pac.h offsets.h
	clang $(ARC_FLAGS) -c nac_pac.m -o $@

meow_memory.o: meow_memory.m meow_memory.h
	clang $(MRC_FLAGS) -c meow_memory.m -o $@

nac_proxy.o: nac_proxy.m nac_proxy.h
	clang $(MRC_FLAGS) -c nac_proxy.m -o $@

.PHONY: clean find-offsets check once
clean:
	rm -f $(BIN) $(OBJS)

find-offsets: $(BIN)
	./$(BIN) -find-offsets

check: $(BIN)
	./$(BIN) -check-compatibility

once: $(BIN)
	./$(BIN) -once
