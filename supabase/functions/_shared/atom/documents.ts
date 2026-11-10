import { JsonApiService, LegalDocument } from "@digitalvirgo/atom-api";
import { AtomProduct, type ProductDto } from "./product.ts";

interface Document {
  id: string;
  name: string;
  documentType: string;
}

function documentFromLegalDocument(doc: LegalDocument): Document | null {
  // The SDK declares this attribute as Enum, but Atom returns the type key.
  const value: unknown = doc.documentType;
  const documentType = typeof value === "string" ? value.trim() : "";
  if (!documentType) return null;
  const name = String(doc.name ?? "").trim() || documentType;
  return { id: String(doc.id ?? ""), name, documentType };
}

function documentsFromProductFind(product: ProductDto): Document[] {
  const fromProduct = (product.legalDocuments ?? [])
    .map(documentFromLegalDocument)
    .filter((document): document is Document => document !== null);
  if (fromProduct.length > 0) return fromProduct;

  const included = product.included ?? [];
  return included
    .filter((item) => item.type === undefined || item.type === "legaldocuments")
    .map(documentFromLegalDocument)
    .filter((document): document is Document => document !== null);
}

function discoverDocuments(product: ProductDto) {
  const documents = documentsFromProductFind(product);
  return {
    documents: documents.map((document) => ({
      id: document.id,
      name: document.name,
      sourceDocumentFormat: document.name,
      documentFormat: document.documentType,
    })),
    formatsDiscovered: documents.map((document) => document.documentType),
  };
}

async function fetchDocumentHtml(
  api: JsonApiService,
  atomProductId: number,
  documentType: string,
  language: string,
  date?: string,
): Promise<string> {
  const day = date ?? new Date().toISOString().split("T")[0];
  const path =
    `products/${atomProductId}/document/${documentType}/html/${language}/${day}`;
  const { body, status } = await api.getVisualiseLegalDocuments(path);
  if (status < 200 || status >= 300) {
    throw new Error(`Document not found: ${documentType}/${language}`);
  }
  return await body.text();
}

export class AtomDocuments extends AtomProduct {
  async discover(atomProductId: number) {
    const product = await this.getProduct(atomProductId, "legaldocuments");
    return discoverDocuments(product);
  }

  async getDocumentHtml(
    atomProductId: number,
    format: string,
    language: string,
    date?: string,
  ): Promise<string> {
    return await fetchDocumentHtml(
      await this.getApi(), atomProductId, format, language, date,
    );
  }
}
