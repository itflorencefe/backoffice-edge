import type { SupabaseClient } from "npm:@supabase/supabase-js@2.49.1";

export interface ResolveProductParams {
  domain?: string;
  bundle_id?: string;
  country_code?: string;
  service_slug?: string;
  environment?: "staging" | "production";
}

export interface ResolvedProduct {
  detected_by: "domain" | "bundle_id+country" | "bundle_id+default" | "slug+country" | "slug+default";
  service: { id: string; slug: string; display_name: string };
  product: {
    id: string;
    slug: string;
    country_code: string;
    display_name: string;
    native_bundle_id: string | null;
    hostname_staging: string | null;
    hostname_production: string | null;
  };
}

export async function resolveProduct(
  supabase: SupabaseClient,
  params: ResolveProductParams,
): Promise<ResolvedProduct> {
  const env = params.environment ?? "production";

  // Strategy 1: domain resolution
  if (params.domain) {
    const hostnameCol = env === "staging" ? "hostname_staging" : "hostname_production";
    const { data: product, error } = await supabase
      .schema("backoffice").from("products")
      .select("id, slug, display_name, country_code, native_bundle_id, hostname_staging, hostname_production, service_id")
      .eq(hostnameCol, params.domain)
      .eq("status", "active")
      .maybeSingle();

    if (error) throw new Error(`Domain lookup failed: ${error.message}`);
    if (product) {
      const { data: svc } = await supabase
        .schema("backoffice").from("services")
        .select("id, slug, display_name")
        .eq("id", product.service_id)
        .single();
      return {
        detected_by: "domain",
        service: svc!,
        product: { id: product.id, slug: product.slug, country_code: product.country_code, display_name: product.display_name, native_bundle_id: product.native_bundle_id, hostname_staging: product.hostname_staging, hostname_production: product.hostname_production },
      };
    }
  }

  // Strategy 2: bundle_id + country_code
  if (params.bundle_id && params.country_code) {
    const { data: product, error } = await supabase
      .schema("backoffice").from("products")
      .select("id, slug, display_name, country_code, native_bundle_id, hostname_staging, hostname_production, service_id")
      .eq("native_bundle_id", params.bundle_id)
      .eq("country_code", params.country_code.toUpperCase())
      .eq("status", "active")
      .maybeSingle();

    if (error) throw new Error(`Bundle+country lookup failed: ${error.message}`);
    if (product) {
      const { data: svc } = await supabase
        .schema("backoffice").from("services")
        .select("id, slug, display_name")
        .eq("id", product.service_id)
        .single();
      return {
        detected_by: "bundle_id+country",
        service: svc!,
        product: { id: product.id, slug: product.slug, country_code: product.country_code, display_name: product.display_name, native_bundle_id: product.native_bundle_id, hostname_staging: product.hostname_staging, hostname_production: product.hostname_production },
      };
    }
  }

  // Strategy 3: bundle_id only (default product for that bundle's service)
  if (params.bundle_id) {
    const { data: product, error } = await supabase
      .schema("backoffice").from("products")
      .select("id, slug, display_name, country_code, native_bundle_id, hostname_staging, hostname_production, service_id")
      .eq("native_bundle_id", params.bundle_id)
      .eq("is_default", true)
      .eq("status", "active")
      .maybeSingle();

    if (error) throw new Error(`Bundle default lookup failed: ${error.message}`);
    if (product) {
      const { data: svc } = await supabase
        .schema("backoffice").from("services")
        .select("id, slug, display_name")
        .eq("id", product.service_id)
        .single();
      return {
        detected_by: "bundle_id+default",
        service: svc!,
        product: { id: product.id, slug: product.slug, country_code: product.country_code, display_name: product.display_name, native_bundle_id: product.native_bundle_id, hostname_staging: product.hostname_staging, hostname_production: product.hostname_production },
      };
    }
  }

  // Strategy 4: service_slug + country_code
  if (params.service_slug && params.country_code) {
    const { data: svc, error: svcErr } = await supabase
      .schema("backoffice").from("services")
      .select("id, slug, display_name")
      .eq("slug", params.service_slug)
      .eq("status", "active")
      .maybeSingle();

    if (svcErr) throw new Error(`Service lookup failed: ${svcErr.message}`);
    if (!svc) throw new Error(`Service '${params.service_slug}' not found or inactive`);

    const { data: product, error } = await supabase
      .schema("backoffice").from("products")
      .select("id, slug, display_name, country_code, native_bundle_id, hostname_staging, hostname_production")
      .eq("service_id", svc.id)
      .eq("country_code", params.country_code.toUpperCase())
      .eq("status", "active")
      .maybeSingle();

    if (error) throw new Error(`Product lookup failed: ${error.message}`);
    if (product) {
      return {
        detected_by: "slug+country",
        service: svc,
        product: { id: product.id, slug: product.slug, country_code: product.country_code, display_name: product.display_name, native_bundle_id: product.native_bundle_id, hostname_staging: product.hostname_staging, hostname_production: product.hostname_production },
      };
    }
  }

  // Strategy 5: service_slug only (default product)
  if (params.service_slug) {
    const { data: svc, error: svcErr } = await supabase
      .schema("backoffice").from("services")
      .select("id, slug, display_name")
      .eq("slug", params.service_slug)
      .eq("status", "active")
      .maybeSingle();

    if (svcErr) throw new Error(`Service lookup failed: ${svcErr.message}`);
    if (!svc) throw new Error(`Service '${params.service_slug}' not found or inactive`);

    const { data: product, error } = await supabase
      .schema("backoffice").from("products")
      .select("id, slug, display_name, country_code, native_bundle_id, hostname_staging, hostname_production")
      .eq("service_id", svc.id)
      .eq("is_default", true)
      .eq("status", "active")
      .maybeSingle();

    if (error) throw new Error(`Default product lookup failed: ${error.message}`);
    if (!product) throw new Error(`No default product for service '${params.service_slug}'`);

    return {
      detected_by: "slug+default",
      service: svc,
      product: { id: product.id, slug: product.slug, country_code: product.country_code, display_name: product.display_name, native_bundle_id: product.native_bundle_id, hostname_staging: product.hostname_staging, hostname_production: product.hostname_production },
    };
  }

  throw new Error("No resolution parameters provided (need domain, bundle_id, or service_slug)");
}
