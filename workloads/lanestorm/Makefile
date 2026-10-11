# lanestorm: two landing streams into one lane (see lanestorm.S). Runs on the core bench
# (tb_core) through run.sh; the image is the byte hex tb_smolrv64_riscv.v reads.
platform=$(shell uname -o)

ifeq ($(platform),Darwin)
  RV=riscv64-elf-
else # Assume Linux
  RV=riscv64-linux-gnu-
endif

lanestorm.hex: lanestorm.bin
	od -An -v -tx1 lanestorm.bin > lanestorm.hex

lanestorm.bin: lanestorm.elf
	$(RV)objcopy -O binary lanestorm.elf lanestorm.bin

lanestorm.elf: lanestorm.S ../fphammer/fphammer.ld
	$(RV)gcc -mabi=lp64d -mcmodel=medany -march=rv64gc_zicsr -nostdlib -static \
		-Wl,-T../fphammer/fphammer.ld lanestorm.S -o lanestorm.elf

clean:
	rm -f lanestorm.elf lanestorm.bin lanestorm.hex
