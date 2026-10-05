/* Minimal KVM test: can userspace write MIDR_EL1?
 *
 * arm64 requires KVM_ARM_VCPU_INIT before the ONE_REG accessors will work;
 * without it every call returns EINVAL (which errno prints as "Exec format
 * error", an easy thing to misread).
 *
 * Hypothesis: 4.14 freezes the invariant ID registers once, at boot, on one
 * core, and set_invariant_sys_reg() rejects any write that differs:
 *
 *     if (r->val != val) return -EINVAL;
 *
 * On big.LITTLE the clusters report different MIDR values, so the write
 * carrying the other cluster's value must fail while the one matching the
 * boot core succeeds.  That failure is what QEMU reports as
 * "Failed to put registers after init".
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sched.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/kvm.h>

#define MIDR_A55 0x00000000412fd050ULL
#define MIDR_A76 0x00000000414fd0b0ULL

#define SYSREG(op0, op1, crn, crm, op2) \
	(KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM64_SYSREG | \
	 ((unsigned long long)(op0) << KVM_REG_ARM64_SYSREG_OP0_SHIFT) | \
	 ((unsigned long long)(op1) << KVM_REG_ARM64_SYSREG_OP1_SHIFT) | \
	 ((unsigned long long)(crn) << KVM_REG_ARM64_SYSREG_CRN_SHIFT) | \
	 ((unsigned long long)(crm) << KVM_REG_ARM64_SYSREG_CRM_SHIFT) | \
	 ((unsigned long long)(op2) << KVM_REG_ARM64_SYSREG_OP2_SHIFT))

#define MIDR_EL1_REGID      SYSREG(3, 0, 0, 0, 0)
#define ID_AA64PFR0_REGID   SYSREG(3, 0, 0, 4, 0)
#define ID_AA64ISAR0_REGID  SYSREG(3, 0, 0, 6, 0)

static int where(void)
{
	return sched_getcpu();
}

static const char *errname(int e)
{
	switch (e) {
	case 0:     return "OK";
	case EINVAL:return "EINVAL";
	case ENOENT:return "ENOENT";
	case EBUSY: return "EBUSY";
	case EFAULT:return "EFAULT";
	default:    return strerror(e);
	}
}

int main(void)
{
	int kvm, vm, vcpu, ret, e;
	unsigned long long v;
	struct kvm_vcpu_init init;
	unsigned long features[] = { KVM_ARM_VCPU_PSCI_0_2, KVM_ARM_VCPU_POWER_OFF };

	printf("=== running on cpu %d ===\n", where());

	kvm = open("/dev/kvm", O_RDWR);
	if (kvm < 0) { perror("open /dev/kvm"); return 1; }

	vm = ioctl(kvm, KVM_CREATE_VM, 0);
	if (vm < 0) { perror("KVM_CREATE_VM"); return 1; }

	vcpu = ioctl(vm, KVM_CREATE_VCPU, 0);
	if (vcpu < 0) { perror("KVM_CREATE_VCPU"); return 1; }

	/* arm64: this is mandatory before any ONE_REG access */
	memset(&init, 0, sizeof init);
	init.target = KVM_ARM_TARGET_GENERIC_V8;
	init.features[0] = (1 << KVM_ARM_VCPU_PSCI_0_2) | (1 << KVM_ARM_VCPU_POWER_OFF);
	ret = ioctl(vcpu, KVM_ARM_VCPU_INIT, &init);
	if (ret < 0) {
		printf("KVM_ARM_VCPU_INIT failed: %s\n", errname(errno));
		return 1;
	}
	(void)features;
	printf("KVM_ARM_VCPU_INIT ok\n\n");

	/* ---- MIDR_EL1 ---- */
	v = 0; errno = 0;
	ret = ioctl(vcpu, KVM_GET_ONE_REG, &(struct kvm_one_reg){
		.id = MIDR_EL1_REGID, .addr = (unsigned long)&v });
	printf("MIDR_EL1            read   -> %s  value=0x%016llx\n",
	       ret ? errname(errno) : "OK", v);

	errno = 0;
	ret = ioctl(vcpu, KVM_SET_ONE_REG, &(struct kvm_one_reg){
		.id = MIDR_EL1_REGID, .addr = (unsigned long)&(unsigned long long){MIDR_A55} });
	e = errno;
	printf("MIDR_EL1  <- A55    write  -> %s\n", errname(e));

	errno = 0;
	ret = ioctl(vcpu, KVM_SET_ONE_REG, &(struct kvm_one_reg){
		.id = MIDR_EL1_REGID, .addr = (unsigned long)&(unsigned long long){MIDR_A76} });
	e = errno;
	printf("MIDR_EL1  <- A76    write  -> %s\n", errname(e));

	errno = 0;
	ret = ioctl(vcpu, KVM_SET_ONE_REG, &(struct kvm_one_reg){
		.id = MIDR_EL1_REGID, .addr = (unsigned long)&(unsigned long long){0xdeadbeefULL} });
	e = errno;
	printf("MIDR_EL1  <- junk   write  -> %s\n", errname(e));

	/* ---- ID_AA64* : not in 4.14's invariant table ---- */
	v = 0;
	errno = 0;
	ret = ioctl(vcpu, KVM_GET_ONE_REG, &(struct kvm_one_reg){
		.id = ID_AA64PFR0_REGID, .addr = (unsigned long)&v });
	printf("\nID_AA64PFR0_EL1     read   -> %s  value=0x%016llx\n",
	       ret ? errname(errno) : "OK", v);

	v = 0;
	errno = 0;
	ret = ioctl(vcpu, KVM_GET_ONE_REG, &(struct kvm_one_reg){
		.id = ID_AA64ISAR0_REGID, .addr = (unsigned long)&v });
	printf("ID_AA64ISAR0_EL1    read   -> %s  value=0x%016llx\n",
	       ret ? errname(errno) : "OK", v);

	/* write the same value back - this is what QEMU does */
	errno = 0;
	ret = ioctl(vcpu, KVM_SET_ONE_REG, &(struct kvm_one_reg){
		.id = ID_AA64PFR0_REGID, .addr = (unsigned long)&(unsigned long long){0} });
	printf("ID_AA64PFR0_EL1 <-0  write  -> %s\n", errname(errno));

	close(vcpu); close(vm); close(kvm);
	return 0;
}
