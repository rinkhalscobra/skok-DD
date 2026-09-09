import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey",
};

type CrmRole = "customer" | "agent" | "superior_manager" | "admin";
type AdminClient = ReturnType<typeof createClient>;

const allowedKycStatuses = new Set(["pending", "submitted", "approved", "rejected"]);

function optionalString(value: unknown) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function wait(milliseconds: number) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function normalizeCrmRole(value: unknown, isAdmin: boolean): CrmRole {
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    if (["customer", "agent", "superior_manager", "admin"].includes(normalized)) {
      return normalized as CrmRole;
    }
  }

  return isAdmin ? "admin" : "customer";
}

async function removeKycDocuments(adminClient: AdminClient, userId: string) {
  const bucket = adminClient.storage.from("kyc-documents");
  const paths: string[] = [];
  const pageSize = 100;
  let offset = 0;

  while (true) {
    const { data, error } = await bucket.list(userId, {
      limit: pageSize,
      offset,
      sortBy: { column: "name", order: "asc" },
    });

    if (error) return error.message;

    const entries = data ?? [];
    paths.push(
      ...entries
        .filter((entry) => entry.name && entry.name !== ".emptyFolderPlaceholder")
        .map((entry) => `${userId}/${entry.name}`),
    );

    if (entries.length < pageSize) break;
    offset += pageSize;
  }

  for (let index = 0; index < paths.length; index += 100) {
    const { error } = await bucket.remove(paths.slice(index, index + 100));
    if (error) return error.message;
  }

  return null;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  try {
    const authHeader = req.headers.get("Authorization");
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseAnonKey =
      Deno.env.get("SB_PUBLISHABLE_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY");
    const supabaseServiceRoleKey =
      Deno.env.get("SB_SECRET_KEY") ??
      Deno.env.get("SUPABASE_SECRET_KEY") ??
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
      Deno.env.get("SERVICE_ROLE_KEY");
    const missingEnv = [
      !supabaseUrl ? "SUPABASE_URL" : null,
      !supabaseAnonKey ? "SUPABASE_ANON_KEY" : null,
      !supabaseServiceRoleKey ? "SUPABASE_SERVICE_ROLE_KEY" : null,
    ].filter(Boolean);

    if (!authHeader) {
      return jsonResponse({ error: "Missing Authorization header" }, 401);
    }

    if (missingEnv.length > 0) {
      return jsonResponse(
        { error: `Missing function environment configuration: ${missingEnv.join(", ")}` },
        500,
      );
    }

    const callerClient = createClient(supabaseUrl!, supabaseAnonKey!, {
      global: { headers: { Authorization: authHeader } },
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const adminClient = createClient(supabaseUrl!, supabaseServiceRoleKey!, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const {
      data: { user: caller },
      error: callerError,
    } = await callerClient.auth.getUser();

    if (callerError || !caller) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const { data: callerProfile, error: callerProfileError } = await adminClient
      .from("profiles")
      .select("crm_role, is_admin, assigned_manager_id")
      .eq("id", caller.id)
      .maybeSingle();

    const callerRole = normalizeCrmRole(
      callerProfile?.crm_role,
      Boolean(callerProfile?.is_admin),
    );

    if (callerProfileError || !["admin", "superior_manager", "agent"].includes(callerRole)) {
      return jsonResponse({ error: "Forbidden" }, 403);
    }

    const payload = await req.json();
    const action = typeof payload.action === "string" ? payload.action : "update";

    if (action === "create") {
      const fullName = typeof payload.full_name === "string" ? payload.full_name.trim() : "";
      const email = typeof payload.email === "string" ? payload.email.trim().toLowerCase() : "";
      const password = typeof payload.password === "string" ? payload.password : "";
      const requestedRole = normalizeCrmRole(payload.crm_role, false);
      const allowedRoles: CrmRole[] = callerRole === "admin"
        ? ["customer", "agent", "superior_manager", "admin"]
        : callerRole === "superior_manager"
        ? ["customer", "agent"]
        : ["customer"];

      if (!fullName) return jsonResponse({ error: "Full name is required" }, 400);
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
        return jsonResponse({ error: "Enter a valid email address" }, 400);
      }
      if (password.length < 6) {
        return jsonResponse({ error: "Password must be at least 6 characters" }, 400);
      }
      if (!allowedRoles.includes(requestedRole)) {
        return jsonResponse({ error: `${callerRole} cannot create the requested CRM role` }, 403);
      }

      const requestedManagerId = optionalString(payload.assigned_manager_id);
      const requestedAgentId = optionalString(payload.assigned_agent_id);
      const assignedManagerId = callerRole === "agent"
        ? optionalString(callerProfile?.assigned_manager_id)
        : callerRole === "superior_manager"
        ? caller.id
        : requestedRole === "customer" || requestedRole === "agent"
        ? requestedManagerId
        : null;
      const assignedAgentId = callerRole === "agent"
        ? caller.id
        : requestedRole === "customer"
        ? requestedAgentId
        : null;
      const kycStatus = allowedKycStatuses.has(String(payload.kyc_status))
        ? String(payload.kyc_status)
        : "pending";
      const emailConfirm = payload.email_confirm !== false;

      const { data: createdAuth, error: createAuthError } = await adminClient.auth.admin.createUser({
        email,
        password,
        email_confirm: emailConfirm,
        user_metadata: { full_name: fullName },
      });

      if (createAuthError || !createdAuth.user) {
        return jsonResponse({ error: createAuthError?.message || "Could not create the login" }, 400);
      }

      const createdUserId = createdAuth.user.id;

      try {
        let generatedProfile: Record<string, unknown> | null = null;
        for (let attempt = 0; attempt < 10; attempt += 1) {
          const { data } = await adminClient
            .from("profiles")
            .select("*")
            .eq("id", createdUserId)
            .maybeSingle();
          if (data) {
            generatedProfile = data;
            break;
          }
          await wait(150);
        }

        const profilePayload: Record<string, unknown> = {
          id: createdUserId,
          full_name: fullName,
          email,
          account_iban: typeof payload.account_iban === "string" ? payload.account_iban.trim().toUpperCase() : "",
          kyc_status: kycStatus,
          crm_role: requestedRole,
          is_admin: requestedRole === "admin",
          assigned_manager_id: assignedManagerId,
          assigned_agent_id: assignedAgentId,
          plain_password: password,
          updated_at: new Date().toISOString(),
        };

        if (typeof payload.account_created_at === "string" && !Number.isNaN(Date.parse(payload.account_created_at))) {
          profilePayload.created_at = new Date(payload.account_created_at).toISOString();
        }
        if (typeof payload.show_account_created_at === "boolean") {
          profilePayload.show_account_created_at = payload.show_account_created_at;
        }

        let profileResult = generatedProfile
          ? await adminClient.from("profiles").update(profilePayload).eq("id", createdUserId).select("*").single()
          : await adminClient.from("profiles").insert(profilePayload).select("*").single();

        for (let attempt = 0; attempt < 6 && profileResult.error; attempt += 1) {
          const missingColumn = profileResult.error.message.match(/'([^']+)' column/)?.[1];
          if (!missingColumn || !(missingColumn in profilePayload)) break;
          delete profilePayload[missingColumn];
          profileResult = generatedProfile
            ? await adminClient.from("profiles").update(profilePayload).eq("id", createdUserId).select("*").single()
            : await adminClient.from("profiles").insert(profilePayload).select("*").single();
        }

        if (profileResult.error || !profileResult.data) {
          throw new Error(profileResult.error?.message || "The CRM profile could not be configured");
        }

        let balanceWarning: string | null = null;
        const { error: balanceError } = await adminClient.from("fiat_balances").upsert([
          { user_id: createdUserId, currency: "USD", name: "US Dollar", balance: 0, status: "available", display_order: 0 },
          { user_id: createdUserId, currency: "EUR", name: "Euro", balance: 0, status: "available", display_order: 1 },
          { user_id: createdUserId, currency: "CAD", name: "Canadian Dollar", balance: 0, status: "available", display_order: 2 },
          { user_id: createdUserId, currency: "CHF", name: "Swiss Franc", balance: 0, status: "available", display_order: 3 },
        ], { onConflict: "user_id,currency", ignoreDuplicates: true });
        if (balanceError) balanceWarning = balanceError.message;

        return jsonResponse({
          success: true,
          action: "create",
          balance_warning: balanceWarning,
          profile: profileResult.data,
          user: {
            id: createdUserId,
            email: createdAuth.user.email,
            email_confirmed: Boolean(createdAuth.user.email_confirmed_at),
          },
        }, 201);
      } catch (createError) {
        const rollbackResult = await adminClient.auth.admin.deleteUser(createdUserId, false);
        const message = createError instanceof Error ? createError.message : "Account setup failed";
        return jsonResponse({
          error: message,
          rollback_warning: rollbackResult.error?.message || null,
        }, 500);
      }
    }

    const targetUserId = typeof payload.user_id === "string" ? payload.user_id.trim() : "";

    if (!targetUserId) {
      return jsonResponse({ error: "user_id is required" }, 400);
    }

    const { data: visibleTarget, error: visibleTargetError } = await callerClient
      .from("profiles")
      .select("id, email, full_name, crm_role, is_admin")
      .eq("id", targetUserId)
      .maybeSingle();

    if (visibleTargetError || !visibleTarget) {
      return jsonResponse({ error: "You do not have access to that user" }, 403);
    }

    if (action === "get_kyc_documents") {
      const { data: submissions, error: submissionsError } = await adminClient
        .from("kyc_submissions")
        .select("*")
        .eq("user_id", targetUserId)
        .order("submitted_at", { ascending: false });

      if (submissionsError) {
        return jsonResponse({ error: `Could not load KYC submissions: ${submissionsError.message}` }, 500);
      }

      const documentFields = [
        { field: "id_front_url", kind: "id_front", label: "ID document - front" },
        { field: "id_back_url", kind: "id_back", label: "ID document - back" },
        { field: "selfie_url", kind: "selfie", label: "Verification selfie" },
      ] as const;
      const bucket = adminClient.storage.from("kyc-documents");

      const signedSubmissions = await Promise.all((submissions ?? []).map(async (submission) => {
        const documents = await Promise.all(documentFields.map(async ({ field, kind, label }) => {
          const path = typeof submission[field] === "string" ? submission[field].trim() : "";
          if (!path) return null;

          // Never sign a path outside the selected customer's storage folder.
          if (!path.startsWith(`${targetUserId}/`)) {
            return { kind, label, path, signed_url: null, error: "Invalid document path" };
          }

          const { data, error } = await bucket.createSignedUrl(path, 10 * 60);
          return {
            kind,
            label,
            path,
            signed_url: data?.signedUrl ?? null,
            error: error?.message ?? null,
          };
        }));

        const metadata = { ...submission };
        delete metadata.id_front_url;
        delete metadata.id_back_url;
        delete metadata.selfie_url;

        return {
          ...metadata,
          documents: documents.filter(Boolean),
        };
      }));

      return jsonResponse({
        success: true,
        action: "get_kyc_documents",
        signed_url_expires_in: 600,
        submissions: signedSubmissions,
      });
    }

    if (action === "delete") {
      if (callerRole !== "admin") {
        return jsonResponse({ error: "Only CRM administrators can permanently delete users" }, 403);
      }

      if (targetUserId === caller.id) {
        return jsonResponse({ error: "You cannot delete your own administrator account" }, 409);
      }

      const confirmation = typeof payload.confirm_email === "string"
        ? payload.confirm_email.trim().toLowerCase()
        : "";
      const expectedConfirmation = String(visibleTarget.email || visibleTarget.id)
        .trim()
        .toLowerCase();

      if (!confirmation || confirmation !== expectedConfirmation) {
        return jsonResponse({ error: "The deletion confirmation does not match the selected user" }, 400);
      }

      const targetRole = normalizeCrmRole(
        visibleTarget.crm_role,
        Boolean(visibleTarget.is_admin),
      );

      if (targetRole === "admin") {
        const { data: profiles, error: profilesError } = await adminClient
          .from("profiles")
          .select("crm_role, is_admin");

        if (profilesError) {
          return jsonResponse({ error: `Could not verify administrator coverage: ${profilesError.message}` }, 500);
        }

        const administratorCount = (profiles ?? []).filter(
          (profile) => normalizeCrmRole(profile.crm_role, Boolean(profile.is_admin)) === "admin",
        ).length;

        if (administratorCount <= 1) {
          return jsonResponse({ error: "The last CRM administrator cannot be deleted" }, 409);
        }
      }

      const { error: deleteError } = await adminClient.auth.admin.deleteUser(
        targetUserId,
        false,
      );

      if (deleteError) {
        return jsonResponse(
          {
            error: `User deletion failed: ${deleteError.message}`,
            hint: "Apply the cascade-user-account-deletion migration before retrying.",
          },
          409,
        );
      }

      const storageCleanupWarning = await removeKycDocuments(adminClient, targetUserId);

      return jsonResponse({
        success: true,
        action: "delete",
        storage_cleanup_warning: storageCleanupWarning,
        deleted_user: {
          id: targetUserId,
          email: visibleTarget.email,
          full_name: visibleTarget.full_name,
        },
      });
    }

    if (action !== "update") {
      return jsonResponse({ error: "Unsupported user-management action" }, 400);
    }

    const email = typeof payload.email === "string" ? payload.email.trim() : undefined;
    const password = typeof payload.password === "string" ? payload.password : undefined;
    const fullName = typeof payload.full_name === "string" ? payload.full_name.trim() : undefined;
    const updatePayload: {
      email?: string;
      password?: string;
      user_metadata?: { full_name?: string };
    } = {};

    if (email) updatePayload.email = email;
    if (password && password.trim().length > 0) updatePayload.password = password;
    if (fullName) updatePayload.user_metadata = { full_name: fullName };

    if (Object.keys(updatePayload).length === 0) {
      return jsonResponse({ error: "No auth fields supplied for update" }, 400);
    }

    const { data, error } = await adminClient.auth.admin.updateUserById(
      targetUserId,
      updatePayload,
    );

    if (error) {
      return jsonResponse({ error: error.message }, 400);
    }

    let profileSyncWarning: string | null = null;

    if (password && password.trim().length > 0) {
      const { error: profileSyncError } = await adminClient
        .from("profiles")
        .update({
          plain_password: password,
          updated_at: new Date().toISOString(),
        })
        .eq("id", targetUserId);

      if (profileSyncError) {
        profileSyncWarning = profileSyncError.message;
        console.error("Failed to sync profiles.plain_password", profileSyncError);
      }
    }

    return jsonResponse({
      success: true,
      action: "update",
      profile_sync_warning: profileSyncWarning,
      user: {
        id: data.user?.id,
        email: data.user?.email,
      },
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unexpected error";
    return jsonResponse({ error: message }, 500);
  }
});
