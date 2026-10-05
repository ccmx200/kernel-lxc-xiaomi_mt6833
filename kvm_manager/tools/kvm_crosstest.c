/* The exact QEMU failure, reproduced in isolation.
 *
 * QEMU reads the host CPU model (wherever its thread is) and writes those same
 * values back through KVM_SET_ONE_REG.  Before the per-VM snapshot that
 * read-then-write-back failed with EINVAL whenever the two steps landed on
 * different clusters, which is the "Failed to put registers after init"
 * abort.
 *
 * This does exactly that: read on one core, write that same value back from a
 * thread on the other core.  Success means the failure mode is gone.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <sched.h>
#include <pthread.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/kvm.h>

#define SYSREG(op0, op1, crn, crm, op2) \
	(KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM64_SYSREG | \
	 ((unsigned long long)(op0) << KVM_REG_ARM64_SYSREG_OP0_SHIFT) | \
	 ((unsigned long long)(op1) << KVM_REG_ARM64_SYSREG_OP1_SHIFT) | \
	 ((unsigned long long)(crn) << KVM_REG_ARM64_SYSREG_CRN_SHIFT) | \
	 ((unsigned long long)(crm) << KVM_REG_ARM64_SYSREG_CRM_SHIFT) | \
	 ((unsigned long long)(op2) << KVM_REG_ARM64_SYSREG_OP2_SHIFT))

struct job { int vcpu; unsigned long long id; int cpu; int rc; int err; unsigned long long val; };

static void pin(int cpu)
{
	cpu_set_t s;
	CPU_ZERO(&s);
	CPU_SET(cpu, &s);
	sched_setaffinity(0, sizeof s, &s);
}

static void *do_read(void *p)
{
	struct job *j = p;
	struct kvm_one_reg r = { .id = j->id, .addr = (unsigned long)&j->val };
	pin(j->cpu);
	j->rc = ioctl(j->vcpu, KVM_GET_ONE_REG, &r);
	j->err = errno;
	return NULL;
}

static void *do_write(void *p)
{
	struct job *j = p;
	struct kvm_one_reg r = { .id = j->id, .addr = (unsigned long)&j->val };
	pin(j->cpu);
	j->rc = ioctl(j->vcpu, KVM_SET_ONE_REG, &r);
	j->err = errno;
	return NULL;
}

int main(void)
{
	int kvm, vm, vcpu;
	struct kvm_vcpu_init init;
	pthread_t t;

	kvm = open("/dev/kvm", O_RDWR);
	vm = ioctl(kvm, KVM_CREATE_VM, 0);
	vcpu = ioctl(vm, KVM_CREATE_VCPU, 0);
	memset(&init, 0, sizeof init);
	init.target = KVM_ARM_TARGET_GENERIC_V8;
	init.features[0] = (1 << KVM_ARM_VCPU_PSCI_0_2);
	ioctl(vcpu, KVM_ARM_VCPU_INIT, &init);

	struct { const char *n; unsigned long long id; } regs[] = {
		{ "MIDR_EL1    ", SYSREG(3,0,0,0,0) },
		{ "REVIDR_EL1  ", SYSREG(3,0,0,0,1) },
		{ "ID_PFR0_EL1 ", SYSREG(3,0,0,1,0) },
		{ "ID_PFR1_EL1 ", SYSREG(3,0,0,1,1) },
		{ "ID_ISAR0_EL1", SYSREG(3,0,0,2,0) },
		{ "CLIDR_EL1   ", SYSREG(3,1,0,0,1) },
		{ "CTR_EL0     ", SYSREG(3,3,0,0,1) },
	};

	printf("QEMU's read-then-write-back, across clusters\n");
	printf("(read on one core, write the SAME value back on the other)\n\n");
	printf("%-14s %-22s %-8s %s\n", "register", "read on", "value", "write back");
	printf("%-14s %-22s %-8s %s\n", "--------------", "----------------------", "--------", "----------");

	int failures = 0;
	for (unsigned i = 0; i < sizeof regs / sizeof regs[0]; i++) {
		/* read on cpu0 (A55), write the very same value on cpu6 (A76) */
		struct job rd = { .vcpu = vcpu, .id = regs[i].id, .cpu = 0 };
		pthread_create(&t, NULL, do_read, &rd); pthread_join(t, NULL);
		if (rd.rc) {
			/* ENOENT means this kernel does not expose the register
			 * through KVM_SET_ONE_REG at all - not a failure of the
			 * thing under test. */
			printf("%-14s %-22s %s\n", regs[i].n, "not exposed",
			       rd.err == ENOENT ? "ENOENT (skipped)" : strerror(rd.err));
			if (rd.err != ENOENT)
				failures++;
			continue;
		}

		struct job wr = { .vcpu = vcpu, .id = regs[i].id, .cpu = 6, .val = rd.val };
		pthread_create(&t, NULL, do_write, &wr); pthread_join(t, NULL);

		printf("%-14s %-22s 0x%016llx %s\n", regs[i].n, "cpu0 -> write cpu6", rd.val,
		       wr.rc ? strerror(wr.err) : "OK");
		if (wr.rc) failures++;
	}

	printf("\n%s\n", failures ? "*** FAILURES - the old failure mode is still present ***"
				  : "all writes accepted across clusters - failure mode gone");

	close(vcpu); close(vm); close(kvm);
	return failures ? 1 : 0;
}
