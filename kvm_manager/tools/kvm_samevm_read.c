/* Same-VM cross-core read test.
 *
 * Build with -D_GNU_SOURCE.
 *
 * Definitive test: one VM, two threads on different clusters.
 *
 * If the per-VM snapshot is in effect, both threads must see the SAME value
 * for a given invariant register, because the read no longer depends on the
 * core the calling thread happens to be on.
 *
 * If the values differ, the snapshot is not being consulted.
 */
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

struct want { int vcpu; unsigned long long id; int cpu; int got; unsigned long long val; int err; };

static void *reader(void *p)
{
	struct want *w = p;
	cpu_set_t s;
	CPU_ZERO(&s);
	CPU_SET(w->cpu, &s);
	sched_setaffinity(0, sizeof s, &s);

	unsigned long long v = 0;
	struct kvm_one_reg r = { .id = w->id, .addr = (unsigned long)&v };
	w->got = ioctl(w->vcpu, KVM_GET_ONE_REG, &r);
	w->err = errno;
	w->val = v;
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
		{ "ID_PFR0_EL1 ", SYSREG(3,0,0,1,0) },
		{ "ID_ISAR0_EL1", SYSREG(3,0,0,2,0) },
		{ "CTR_EL0     ", SYSREG(3,3,0,0,1) },
	};

	printf("VM created on cpu %d\n\n", sched_getcpu());
	printf("%-14s %-20s %-20s %s\n", "register", "read on cpu0", "read on cpu6", "same?");
	printf("%-14s %-20s %-20s %s\n", "--------------", "--------------------", "--------------------", "-----");

	for (unsigned i = 0; i < sizeof regs / sizeof regs[0]; i++) {
		struct want a = { .vcpu = vcpu, .id = regs[i].id, .cpu = 0 };
		struct want b = { .vcpu = vcpu, .id = regs[i].id, .cpu = 6 };
		pthread_create(&t, NULL, reader, &a); pthread_join(t, NULL);
		pthread_create(&t, NULL, reader, &b); pthread_join(t, NULL);

		char sa[32], sb[32];
		snprintf(sa, sizeof sa, a.got ? "err:%d" : "0x%016llx", a.got ? a.err : a.val);
		snprintf(sb, sizeof sb, b.got ? "err:%d" : "0x%016llx", b.got ? b.err : b.val);
		printf("%-14s %-20s %-20s %s\n", regs[i].n, sa, sb,
		       (a.got == 0 && b.got == 0) ? (a.val == b.val ? "YES" : "NO") : "n/a");
	}

	close(vcpu); close(vm); close(kvm);
	return 0;
}
