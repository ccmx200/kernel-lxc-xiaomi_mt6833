/* Exhaustive version of QEMU's operation.
 *
 * Enumerate every register KVM exposes for the vCPU (KVM_GET_REG_LIST), then
 * for each one: read it on cpu0, write the identical value back from cpu6.
 *
 * Any register that fails is core-dependent and not covered by the per-VM
 * snapshot - which is what QEMU is tripping over.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sched.h>
#include <pthread.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/kvm.h>

struct job { int vcpu; unsigned long long id; int cpu;
	     unsigned char buf[256]; int rc; int err; };

static void pin(int cpu)
{
	cpu_set_t s;
	CPU_ZERO(&s); CPU_SET(cpu, &s);
	sched_setaffinity(0, sizeof s, &s);
}

static void *do_read(void *p)
{
	struct job *j = p;
	struct kvm_one_reg r = { .id = j->id, .addr = (unsigned long)j->buf };
	pin(j->cpu);
	j->rc = ioctl(j->vcpu, KVM_GET_ONE_REG, &r);
	j->err = errno;
	return NULL;
}

static void *do_write(void *p)
{
	struct job *j = p;
	struct kvm_one_reg r = { .id = j->id, .addr = (unsigned long)j->buf };
	pin(j->cpu);
	j->rc = ioctl(j->vcpu, KVM_SET_ONE_REG, &r);
	j->err = errno;
	return NULL;
}

static void describe(unsigned long long id, char *out, size_t n)
{
	unsigned long long sz = id & KVM_REG_SIZE_MASK;
	const char *s = "?";
	switch (sz) {
	case KVM_REG_SIZE_U8:  s = "u8 "; break;
	case KVM_REG_SIZE_U16: s = "u16"; break;
	case KVM_REG_SIZE_U32: s = "u32"; break;
	case KVM_REG_SIZE_U64: s = "u64"; break;
	case KVM_REG_SIZE_U128:s = "u128"; break;
	case KVM_REG_SIZE_U256:s = "u256"; break;
	}
	unsigned long long proc = id & KVM_REG_ARM_COPROC_MASK;
	if (proc == KVM_REG_ARM64_SYSREG) {
		unsigned long long op0 = (id >> KVM_REG_ARM64_SYSREG_OP0_SHIFT) & 3;
		unsigned long long op1 = (id >> KVM_REG_ARM64_SYSREG_OP1_SHIFT) & 7;
		unsigned long long crn = (id >> KVM_REG_ARM64_SYSREG_CRN_SHIFT) & 15;
		unsigned long long crm = (id >> KVM_REG_ARM64_SYSREG_CRM_SHIFT) & 15;
		unsigned long long op2 = (id >> KVM_REG_ARM64_SYSREG_OP2_SHIFT) & 7;
		snprintf(out, n, "%s sysreg S3_%llu_C%llu_C%llu_%llu", s, op1, crn, crm, op2);
		(void)op0;
	} else if (proc == KVM_REG_ARM_CORE) {
		snprintf(out, n, "%s core  0x%llx", s, id & 0xffff);
	} else {
		snprintf(out, n, "%s proc=0x%llx 0x%llx", s, proc, id & 0xffffffff);
	}
}

int main(void)
{
	int kvm, vm, vcpu;
	struct kvm_vcpu_init init;
	pthread_t t;
	unsigned long n = 0, i;

	kvm = open("/dev/kvm", O_RDWR);
	vm = ioctl(kvm, KVM_CREATE_VM, 0);
	vcpu = ioctl(vm, KVM_CREATE_VCPU, 0);
	memset(&init, 0, sizeof init);
	init.target = KVM_ARM_TARGET_GENERIC_V8;
	init.features[0] = (1 << KVM_ARM_VCPU_PSCI_0_2);
	ioctl(vcpu, KVM_ARM_VCPU_INIT, &init);

	/* how many registers? */
	ioctl(vcpu, KVM_GET_REG_LIST, (void *)0);
	struct kvm_reg_list *rl = calloc(1, sizeof *rl + 4000 * sizeof(long long));
	rl->n = 4000;
	if (ioctl(vcpu, KVM_GET_REG_LIST, rl) < 0) {
		perror("KVM_GET_REG_LIST");
		return 1;
	}
	n = rl->n;
	printf("KVM exposes %lu registers for this vCPU\n\n", n);

	printf("read on cpu0, write identical value back on cpu6:\n");
	printf("%-34s %-18s %s\n", "register", "value", "write back");
	printf("%-34s %-18s %s\n", "----------------------------------",
	       "------------------", "----------");

	int bad = 0, checked = 0;
	for (i = 0; i < n; i++) {
		unsigned long long sz = rl->reg[i] & KVM_REG_SIZE_MASK;
		if (sz != KVM_REG_SIZE_U32 && sz != KVM_REG_SIZE_U64)
			continue;

		struct job rd; memset(&rd, 0, sizeof rd);
		rd.vcpu = vcpu; rd.id = rl->reg[i]; rd.cpu = 0;
		pthread_create(&t, NULL, do_read, &rd); pthread_join(t, NULL);
		if (rd.rc) continue;
		checked++;

		struct job wr = rd; wr.cpu = 6;
		pthread_create(&t, NULL, do_write, &wr); pthread_join(t, NULL);

		if (wr.rc) {
			char d[64], v[24];
			describe(rd.id, d, sizeof d);
			snprintf(v, sizeof v, "0x%llx",
				 sz == KVM_REG_SIZE_U64 ? *(unsigned long long *)rd.buf
							: (unsigned long long)*(unsigned int *)rd.buf);
			printf("%-34s %-18s %s (errno %d)\n", d, v, strerror(wr.err), wr.err);
			bad++;
		}
	}

	printf("\nchecked %d writable registers, %d failed the cross-cluster write-back\n",
	       checked, bad);
	free(rl);
	close(vcpu); close(vm); close(kvm);
	return bad ? 1 : 0;
}
