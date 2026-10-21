using System.Security.Principal;

namespace DevWS.Setup;

internal static class UserIdentity
{
    internal static SecurityIdentifier CurrentSid()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var sid = identity.User;
        if (sid is null || !sid.IsAccountSid())
        {
            throw new SetupException("The current Windows user SID could not be resolved.");
        }

        return sid;
    }

    internal static bool TryParseSid(string value, out SecurityIdentifier? sid)
    {
        try
        {
            sid = new SecurityIdentifier(value);
            return sid.IsAccountSid();
        }
        catch
        {
            sid = null;
            return false;
        }
    }

    internal static void RequireSameElevatedSid(string callerSidText)
    {
        if (!TryParseSid(callerSidText, out var callerSid) || callerSid is null)
        {
            throw new SetupException("The internal caller SID is malformed.");
        }

        var current = CurrentSid();
        if (!current.Equals(callerSid))
        {
            throw new SetupException(
                "Elevation switched Windows user identities. DevWS package operations require the original caller to remain the same user; nothing was changed.");
        }
    }
}
