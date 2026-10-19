// DevWS privileged identity interop (Security Phase 1).
//
// Narrowly scoped native surface for privileged identity decisions:
//
//   * Windows Terminal package identity: query the registered instances of the
//     OFFICIAL Windows Terminal package family for the current user through the
//     OS appmodel APIs exported by kernel32 (FindPackagesByPackageFamily /
//     PackageFamilyNameFromFullName / GetPackagePathByFullName). This is
//     deliberately NOT built on PowerShell command discovery: no module
//     autoload, no alias/function indirection, no PATH lookup can influence the
//     trusted package query.
//
//   * Process token integrity: read the current process token's mandatory
//     integrity label directly (TokenIntegrityLevel -> SID) so no external
//     executable (previously `whoami /groups`) is needed inside High security
//     contexts.
//
// This file is one of the tracked declarations compiled into the single
// installed DevWS.Native.dll (see src/lib/devws-native.ps1 and install.ps1).

using System;
using System.Runtime.InteropServices;
using System.Text;

public static class DevWSPrivilegeNative
{
    // ---- package identity (appmodel APIs, kernel32) -----------------------

    // PACKAGE_FILTER_HEAD: the head (main) package of each registration.
    public const uint PackageFilterHead = 0x00000010;

    // ERROR_INSUFFICIENT_BUFFER: the sizing call reports the required count and
    // buffer length through this Win32 error.
    public const int ErrorInsufficientBuffer = 122;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int FindPackagesByPackageFamily(
        string packageFamilyName, uint packageFilters,
        out uint count, IntPtr packageFullNames, out uint bufferLength, IntPtr buffer, IntPtr packageProperties);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int PackageFamilyNameFromFullName(
        string packageFullName, ref uint packageFamilyNameLength, StringBuilder packageFamilyName);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetPackagePathByFullName(
        string packageFullName, ref uint pathLength, StringBuilder path);

    // ---- process token integrity ------------------------------------------

    // TOKEN_QUERY access right for OpenProcessToken.
    public const uint TokenQuery = 0x0008;

    // TOKEN_INFORMATION_CLASS.TokenIntegrityLevel.
    public const int TokenIntegrityLevel = 25;

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetCurrentProcess();

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool GetTokenInformation(
        IntPtr tokenHandle, int tokenInformationClass, IntPtr tokenInformation, int tokenInformationLength, out int returnLength);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool ConvertSidToStringSid(IntPtr sid, out IntPtr stringSid);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr LocalFree(IntPtr handle);

    // ---- exclusive secure directory creation (Public Security Phase 2-A) --

    // SECURITY_ATTRIBUTES for CreateDirectoryW.
    [StructLayout(LayoutKind.Sequential)]
    public struct SECURITY_ATTRIBUTES
    {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        public bool bInheritHandle;
    }

    // BY_HANDLE_FILE_INFORMATION for stable object identity.
    [StructLayout(LayoutKind.Sequential)]
    public struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    public const int ErrorFileExists = 80;
    public const int ErrorAlreadyExists = 183;

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(
        string stringSecurityDescriptor, uint stringSDRevision, out IntPtr securityDescriptor, out uint securityDescriptorSize);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateDirectoryW(string path, ref SECURITY_ATTRIBUTES securityAttributes);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFileW(
        string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes,
        uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetFileInformationByHandle(IntPtr handle, out BY_HANDLE_FILE_INFORMATION information);

    // Exclusive secure directory create. Returns:
    //   0 = this call created the directory with the supplied self-relative SDDL
    //   1 = the path already exists (the SDDL was NOT applied to it; the caller
    //       must validate the existing object and never assume it is ours)
    //   2 = failure (win32Error carries the Win32 error)
    // The kernel performs the create atomically, so the result is authoritative:
    // it can never misclassify a raced object as created by this call.
    public static int SecureCreateDirectory(string path, string sddl, out int win32Error)
    {
        win32Error = 0;

        IntPtr descriptor;
        uint size;

        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, out descriptor, out size))
        {
            win32Error = Marshal.GetLastWin32Error();
            return 2;
        }

        try
        {
            SECURITY_ATTRIBUTES attributes = new SECURITY_ATTRIBUTES();
            attributes.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            attributes.lpSecurityDescriptor = descriptor;
            attributes.bInheritHandle = false;

            if (CreateDirectoryW(path, ref attributes))
            {
                return 0;
            }

            win32Error = Marshal.GetLastWin32Error();

            if (win32Error == ErrorAlreadyExists || win32Error == ErrorFileExists)
            {
                return 1;
            }

            return 2;
        }
        finally
        {
            LocalFree(descriptor);
        }
    }

    // Stable identity of one path object WITHOUT following a reparse point: the
    // handle is opened with FILE_FLAG_OPEN_REPARSE_POINT (so a junction or
    // symlink is inspected as itself) and the returned volume serial + file
    // index identify the exact object for before/after comparisons.
    public static bool TryOpenPathIdentity(string path, out uint volumeSerial, out ulong fileIndex, out uint attributes, out int win32Error)
    {
        volumeSerial = 0;
        fileIndex = 0;
        attributes = 0;
        win32Error = 0;

        const uint FILE_READ_ATTRIBUTES = 0x00000080;
        const uint FILE_SHARE_ALL = 0x00000007;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;

        IntPtr handle = CreateFileW(
            path, FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);

        if (handle == new IntPtr(-1))
        {
            win32Error = Marshal.GetLastWin32Error();
            return false;
        }

        try
        {
            BY_HANDLE_FILE_INFORMATION information;

            if (!GetFileInformationByHandle(handle, out information))
            {
                win32Error = Marshal.GetLastWin32Error();
                return false;
            }

            volumeSerial = information.VolumeSerialNumber;
            fileIndex = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;
            attributes = information.FileAttributes;
            return true;
        }
        finally
        {
            CloseHandle(handle);
        }
    }

    // ---- handle-bound identity + security inspection ----------------------

    [StructLayout(LayoutKind.Sequential)]
    public struct GENERIC_MAPPING
    {
        public uint GenericRead;
        public uint GenericWrite;
        public uint GenericExecute;
        public uint GenericAll;
    }

    // SE_FILE_OBJECT
    public const uint SeFileObject = 1;
    public const uint OwnerSecurityInformation = 0x00000001;
    public const uint GroupSecurityInformation = 0x00000002;
    public const uint DaclSecurityInformation = 0x00000004;

    // FILE_DELETE_CHILD / DELETE / WRITE_DAC / WRITE_OWNER
    public const uint FileDeleteChild = 0x00000040;
    public const uint DeleteAccess = 0x00010000;
    public const uint WriteDacAccess = 0x00040000;
    public const uint WriteOwnerAccess = 0x00080000;

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern uint GetSecurityInfo(
        IntPtr handle, uint objectType, uint securityInfo,
        out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr securityDescriptor);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool ConvertSecurityDescriptorToStringSecurityDescriptorW(
        IntPtr securityDescriptor, uint stringSDRevision, uint securityInformation,
        out IntPtr stringSecurityDescriptor, out uint stringSecurityDescriptorLength);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool AccessCheck(
        IntPtr securityDescriptor, IntPtr clientToken, uint desiredAccess,
        ref GENERIC_MAPPING genericMapping, IntPtr privilegeSet, ref uint privilegeSetLength,
        out uint grantedAccess, out bool accessStatus);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool DuplicateTokenEx(
        IntPtr existingToken, uint desiredAccess, IntPtr tokenAttributes,
        int impersonationLevel, int tokenType, out IntPtr newToken);

    // ---- handle-bound inspection with an explicitly owned lifetime ---------
    //
    // One handle-bound inspection of one path with an explicitly owned
    // lifetime: the handle is opened WITHOUT following reparse points and
    // WITHOUT FILE_SHARE_DELETE, the object identity and the owner/DACL
    // security descriptor are read FROM THAT SAME HANDLE, and the handle
    // stays open (owned by this disposable object) until the caller has
    // completed the entire semantic security decision and disposes it.
    // Identity and security can therefore never describe different objects,
    // and a concurrent rename/delete cannot coexist with the inspection.
    public sealed class PathInspection : IDisposable
    {
        // Owned kernel handle (null when the inspection failed). The
        // SafeFileHandle closes it exactly once, even across double disposal.
        private readonly Microsoft.Win32.SafeHandles.SafeFileHandle handle;

        public bool IsValid { get; private set; }
        public int Win32Error { get; private set; }
        public uint VolumeSerial { get; private set; }
        public ulong FileIndex { get; private set; }
        public uint Attributes { get; private set; }
        public string Sddl { get; private set; }

        // FILE_ATTRIBUTE_DIRECTORY / FILE_ATTRIBUTE_REPARSE_POINT.
        public bool IsDirectory { get { return (Attributes & 0x10) != 0; } }
        public bool IsReparse { get { return (Attributes & 0x400) != 0; } }

        // Failed inspection: no handle is owned; the error is preserved.
        internal PathInspection(int win32Error)
        {
            handle = null;
            IsValid = false;
            Win32Error = win32Error;
            Sddl = null;
        }

        // Successful inspection: takes OWNERSHIP of the open handle.
        internal PathInspection(IntPtr ownedHandle, uint volumeSerial, ulong fileIndex, uint attributes, string sddl)
        {
            handle = new Microsoft.Win32.SafeHandles.SafeFileHandle(ownedHandle, true);
            IsValid = true;
            Win32Error = 0;
            VolumeSerial = volumeSerial;
            FileIndex = fileIndex;
            Attributes = attributes;
            Sddl = sddl;
        }

        public void Dispose()
        {
            if (handle != null) { handle.Dispose(); }
        }
    }

    // Opens the exact path WITHOUT following a reparse point and reads BOTH
    // the identity and the owner/DACL SDDL from the SAME handle; the returned
    // disposable KEEPS THE HANDLE OPEN so the caller can complete the whole
    // semantic ACL validation while the no-delete-share hold is effective,
    // and must dispose it in a finally block (every success, rejection,
    // parsing exception and error path releases the handle exactly once).
    //
    // Share mode deliberately omits FILE_SHARE_DELETE: while the handle is
    // open, a concurrent rename/delete cannot coexist with the inspection
    // (the competing operation fails with a sharing violation), and an
    // already-open delete-capable handle makes this open fail closed.
    public static PathInspection OpenAndInspectPath(string path)
    {
        const uint FILE_LIST_DIRECTORY = 0x00000001;
        const uint FILE_READ_ATTRIBUTES = 0x00000080;
        const uint READ_CONTROL = 0x00020000;
        const uint FILE_SHARE_READ_WRITE = 0x00000003;   // NO FILE_SHARE_DELETE
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;

        // FILE_LIST_DIRECTORY (read-data-class) is required in addition to
        // metadata access: a metadata-only handle does not participate in
        // delete-sharing enforcement, so without it the no-delete-share hold
        // would not actually block a concurrent delete/rename (verified
        // empirically).
        IntPtr handle = CreateFileW(
            path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | READ_CONTROL, FILE_SHARE_READ_WRITE, IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);

        if (handle == new IntPtr(-1))
        {
            return new PathInspection(Marshal.GetLastWin32Error());
        }

        // The raw handle is closed on EVERY failure path; on success its
        // ownership transfers to the returned PathInspection exactly once.
        bool ownershipTransferred = false;

        try
        {
            BY_HANDLE_FILE_INFORMATION information;

            if (!GetFileInformationByHandle(handle, out information))
            {
                return new PathInspection(Marshal.GetLastWin32Error());
            }

            IntPtr owner, group, dacl, sacl, descriptor;

            uint result = GetSecurityInfo(
                handle, SeFileObject,
                OwnerSecurityInformation | GroupSecurityInformation | DaclSecurityInformation,
                out owner, out group, out dacl, out sacl, out descriptor);

            if (result != 0)
            {
                return new PathInspection((int)result);
            }

            string sddl;

            try
            {
                IntPtr text;
                uint textLength;

                if (!ConvertSecurityDescriptorToStringSecurityDescriptorW(
                        descriptor, 1,
                        OwnerSecurityInformation | GroupSecurityInformation | DaclSecurityInformation,
                        out text, out textLength))
                {
                    return new PathInspection(Marshal.GetLastWin32Error());
                }

                try
                {
                    sddl = Marshal.PtrToStringUni(text);
                }
                finally
                {
                    LocalFree(text);
                }
            }
            finally
            {
                LocalFree(descriptor);
            }

            ulong fileIndex = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;

            PathInspection inspection = new PathInspection(handle, information.VolumeSerialNumber, fileIndex, information.FileAttributes, sddl);
            ownershipTransferred = true;
            return inspection;
        }
        finally
        {
            if (!ownershipTransferred)
            {
                CloseHandle(handle);
            }
        }
    }

    // ---- delete-capable claim probe (Public Security Phase 2-B) ------------
    //
    // Used ONLY by protected-capture retention. Opens a claim directory with
    // DELETE access and full sharing (no reparse following): the open FAILS
    // with a sharing violation while any active publication lifetime handle
    // holds the claim without delete sharing, and while this probe is held no
    // NEW no-delete-share holder can start - so a held claim can never have
    // its children deleted by a recursive removal.
    public sealed class ClaimDeleteProbe : IDisposable
    {
        private readonly Microsoft.Win32.SafeHandles.SafeFileHandle handle;

        public bool IsOpen { get { return handle != null; } }
        public int Win32Error { get; private set; }

        internal ClaimDeleteProbe(Microsoft.Win32.SafeHandles.SafeFileHandle ownedHandle, int win32Error)
        {
            handle = ownedHandle;
            Win32Error = win32Error;
        }

        public void Dispose()
        {
            if (handle != null) { handle.Dispose(); }
        }
    }

    public static ClaimDeleteProbe OpenClaimDeleteProbe(string path)
    {
        const uint FILE_LIST_DIRECTORY = 0x00000001;
        const uint FILE_READ_ATTRIBUTES = 0x00000080;
        const uint DELETE = 0x00010000;
        const uint FILE_SHARE_READ_WRITE_DELETE = 0x00000007;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;

        IntPtr handle = CreateFileW(
            path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | DELETE, FILE_SHARE_READ_WRITE_DELETE, IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);

        if (handle == new IntPtr(-1))
        {
            return new ClaimDeleteProbe(null, Marshal.GetLastWin32Error());
        }

        return new ClaimDeleteProbe(new Microsoft.Win32.SafeHandles.SafeFileHandle(handle, true), 0);
    }

    // Anchor access check: opens the anchor WITHOUT following reparse points,
    // resolves the MEDIUM client token (the linked filtered token when the
    // current process runs elevated, otherwise a duplicated impersonation copy
    // of the current Medium token) and performs
    // real AccessCheck evaluations ON THE SAME OPEN HANDLE for
    // FILE_DELETE_CHILD (required to be absent), DELETE, WRITE_DAC and
    // WRITE_OWNER. Returns false (fail closed) when the medium token cannot be
    // obtained reliably or any read fails; usedLinkedToken reports which
    // elevated path supplied the checked subject.
    public static bool TryInspectAnchorAccess(
        string path,
        out uint volumeSerial,
        out ulong fileIndex,
        out uint attributes,
        out bool mediumHasDeleteChild,
        out bool mediumHasDelete,
        out bool mediumHasWriteDac,
        out bool mediumHasWriteOwner,
        out bool mediumTokenObtained,
        out bool usedLinkedToken,
        out int win32Error)
    {
        volumeSerial = 0;
        fileIndex = 0;
        attributes = 0;
        mediumHasDeleteChild = false;
        mediumHasDelete = false;
        mediumHasWriteDac = false;
        mediumHasWriteOwner = false;
        mediumTokenObtained = false;
        usedLinkedToken = false;
        win32Error = 0;

        const uint FILE_LIST_DIRECTORY = 0x00000001;
        const uint FILE_READ_ATTRIBUTES = 0x00000080;
        const uint READ_CONTROL = 0x00020000;
        const uint FILE_SHARE_READ_WRITE = 0x00000003;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        const uint TOKEN_QUERY = 0x0008;
        const uint TOKEN_DUPLICATE = 0x0002;

        const int TokenLinkedTokenClass = 19;
        const int SecurityImpersonation = 2;
        const int TokenImpersonation = 2;

        IntPtr handle = CreateFileW(
            path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | READ_CONTROL, FILE_SHARE_READ_WRITE, IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);

        if (handle == new IntPtr(-1))
        {
            win32Error = Marshal.GetLastWin32Error();
            return false;
        }

        IntPtr currentToken = IntPtr.Zero;
        IntPtr clientToken = IntPtr.Zero;
        bool clientIsLinked = false;
        bool clientIsDuplicate = false;

        try
        {
            BY_HANDLE_FILE_INFORMATION information;

            if (!GetFileInformationByHandle(handle, out information))
            {
                win32Error = Marshal.GetLastWin32Error();
                return false;
            }

            volumeSerial = information.VolumeSerialNumber;
            fileIndex = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;
            attributes = information.FileAttributes;

            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE, out currentToken))
            {
                win32Error = Marshal.GetLastWin32Error();
                return false;
            }

            string integritySid = GetTokenIntegritySid(currentToken);

            if (integritySid == "S-1-16-12288" || integritySid == "S-1-16-16384")
            {
                // Elevated (High) or SYSTEM: the effective Medium authority is
                // the linked filtered token. It must be obtained reliably.
                int needed = 0;
                GetTokenInformation(currentToken, TokenLinkedTokenClass, IntPtr.Zero, 0, out needed);

                if (needed <= 0)
                {
                    win32Error = Marshal.GetLastWin32Error();
                    return false;
                }

                IntPtr linkedBuffer = Marshal.AllocHGlobal(needed);

                try
                {
                    if (!GetTokenInformation(currentToken, TokenLinkedTokenClass, linkedBuffer, needed, out needed))
                    {
                        win32Error = Marshal.GetLastWin32Error();
                        return false;
                    }

                    // TOKEN_LINKED_TOKEN { HANDLE LinkedToken; }
                    clientToken = Marshal.ReadIntPtr(linkedBuffer);
                    clientIsLinked = true;
                }
                finally
                {
                    Marshal.FreeHGlobal(linkedBuffer);
                }

                if (clientToken == IntPtr.Zero)
                {
                    win32Error = 1309; // ERROR_NO_TOKEN
                    return false;
                }

                usedLinkedToken = true;
            }
            else if (integritySid == "S-1-16-8192" || integritySid == "S-1-16-8448")
            {
                // Already Medium (or Medium-Plus): the current primary token
                // IS the same-user Medium authority. AccessCheck requires an
                // impersonation token (a primary handle fails with
                // ERROR_NO_IMPERSONATION_TOKEN), so duplicate it - a copy of
                // the same security context, closed with the other handles.
                if (!DuplicateTokenEx(currentToken, TOKEN_QUERY, IntPtr.Zero, SecurityImpersonation, TokenImpersonation, out clientToken))
                {
                    win32Error = Marshal.GetLastWin32Error();
                    return false;
                }

                clientIsDuplicate = true;
            }
            else
            {
                // Low integrity or an undetermined integrity level: the
                // current token is NOT the same-user Medium authority, and a
                // Medium token cannot be obtained reliably from here. Fail
                // closed instead of checking against a more restrictive or
                // unknown subject.
                win32Error = 1309; // ERROR_NO_TOKEN
                return false;
            }

            IntPtr owner, group, dacl, sacl, descriptor;

            uint result = GetSecurityInfo(handle, SeFileObject, OwnerSecurityInformation | GroupSecurityInformation | DaclSecurityInformation, out owner, out group, out dacl, out sacl, out descriptor);

            if (result != 0)
            {
                win32Error = (int)result;
                return false;
            }

            try
            {
                GENERIC_MAPPING mapping = new GENERIC_MAPPING();
                mapping.GenericRead = 0x120089;
                mapping.GenericWrite = 0x120116;
                mapping.GenericExecute = 0x1200A0;
                mapping.GenericAll = 0x1F01FF;

                if (!CheckAccess(descriptor, clientToken, ref mapping, FileDeleteChild, out mediumHasDeleteChild) ||
                    !CheckAccess(descriptor, clientToken, ref mapping, DeleteAccess, out mediumHasDelete) ||
                    !CheckAccess(descriptor, clientToken, ref mapping, WriteDacAccess, out mediumHasWriteDac) ||
                    !CheckAccess(descriptor, clientToken, ref mapping, WriteOwnerAccess, out mediumHasWriteOwner))
                {
                    win32Error = Marshal.GetLastWin32Error();
                    return false;
                }
            }
            finally
            {
                LocalFree(descriptor);
            }

            mediumTokenObtained = true;
            return true;
        }
        finally
        {
            if ((clientIsLinked || clientIsDuplicate) && clientToken != IntPtr.Zero) { CloseHandle(clientToken); }
            if (currentToken != IntPtr.Zero) { CloseHandle(currentToken); }
            CloseHandle(handle);
        }
    }

    // Single AccessCheck evaluation with a bounded privilege-set buffer.
    static bool CheckAccess(IntPtr descriptor, IntPtr clientToken, ref GENERIC_MAPPING mapping, uint desiredAccess, out bool granted)
    {
        granted = false;

        uint privilegeLength = 1024;
        IntPtr privilegeSet = Marshal.AllocHGlobal(1024);

        try
        {
            uint grantedAccess;
            bool accessStatus;

            if (!AccessCheck(descriptor, clientToken, desiredAccess, ref mapping, privilegeSet, ref privilegeLength, out grantedAccess, out accessStatus))
            {
                return false;
            }

            granted = accessStatus && (grantedAccess & desiredAccess) == desiredAccess;
            return true;
        }
        finally
        {
            Marshal.FreeHGlobal(privilegeSet);
        }
    }

    // Current-token integrity SID string (null on any failure).
    static string GetTokenIntegritySid(IntPtr token)
    {
        const int TokenIntegrityLevelClass = 25;

        try
        {
            int needed = 0;
            GetTokenInformation(token, TokenIntegrityLevelClass, IntPtr.Zero, 0, out needed);

            if (needed <= 0) { return null; }

            IntPtr buffer = Marshal.AllocHGlobal(needed);

            try
            {
                if (!GetTokenInformation(token, TokenIntegrityLevelClass, buffer, needed, out needed)) { return null; }

                // TOKEN_MANDATORY_LABEL { SID_AND_ATTRIBUTES Label; } where
                // SID_AND_ATTRIBUTES { PSID Sid; DWORD Attributes; }
                IntPtr sid = Marshal.ReadIntPtr(buffer);

                IntPtr stringPtr;

                if (!ConvertSidToStringSid(sid, out stringPtr)) { return null; }

                try
                {
                    return Marshal.PtrToStringUni(stringPtr);
                }
                finally
                {
                    LocalFree(stringPtr);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
        catch
        {
            return null;
        }
    }
}
