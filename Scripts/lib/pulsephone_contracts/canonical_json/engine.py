from dataclasses import dataclass
import hashlib
import json
from typing import Any, Dict, Mapping, Sequence, Tuple


INT64_MIN = -(1 << 63)
INT64_MAX = (1 << 63) - 1
UINT64_MAX = (1 << 64) - 1


class CanonicalJSONError(ValueError):
    def __init__(self, kind: str, detail: str = "") -> None:
        self.kind = kind
        self.detail = detail
        super().__init__(kind if not detail else f"{kind}: {detail}")


@dataclass(frozen=True)
class CanonicalJSONDocument:
    root: Mapping[str, Any]
    exact_bytes: bytes

    @property
    def sha256_hex(self) -> str:
        return sha256_hex(self.exact_bytes)

    def domain_separated_sha256_hex(self, domain_id: str) -> str:
        return domain_separated_sha256_hex(domain_id, self.exact_bytes)


def validate_document(data: bytes, maximum_byte_count: int) -> CanonicalJSONDocument:
    if maximum_byte_count < 0:
        raise CanonicalJSONError("invalidMaximumByteCount")
    if len(data) > maximum_byte_count:
        raise CanonicalJSONError("hardCapExceeded")
    if data.startswith(b"\xef\xbb\xbf"):
        raise CanonicalJSONError("bom")
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise CanonicalJSONError("invalidUTF8", str(error)) from error
    try:
        root = json.loads(
            text,
            object_pairs_hook=_object_from_pairs,
            parse_int=_parse_integer,
            parse_float=_reject_float,
            parse_constant=_reject_constant,
            strict=True,
        )
    except CanonicalJSONError:
        raise
    except json.JSONDecodeError as error:
        kind = "invalidStringControl" if "Invalid control character" in error.msg else "invalidSyntax"
        raise CanonicalJSONError(kind, error.msg) from error
    _validate_unicode_scalars(root)
    if not isinstance(root, dict):
        raise CanonicalJSONError("topLevelObject")
    if encode_document(root) != data:
        raise CanonicalJSONError("nonCanonical")
    return CanonicalJSONDocument(root=root, exact_bytes=data)


def encode_document(root: Mapping[str, Any]) -> bytes:
    if not isinstance(root, dict):
        raise CanonicalJSONError("topLevelObject")
    _validate_unicode_scalars(root)
    return _encode_value(root).encode("utf-8")


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def domain_separated_sha256_hex(domain_id: str, payload: bytes) -> str:
    try:
        domain = domain_id.encode("ascii", errors="strict")
    except UnicodeEncodeError as error:
        raise CanonicalJSONError("invalidDomainID", str(error)) from error
    if b"\0" in domain:
        raise CanonicalJSONError("invalidDomainID")
    return sha256_hex(domain + b"\0" + payload)


def require_uint64(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= UINT64_MAX:
        raise CanonicalJSONError("integerNotUInt64")
    return value


def require_int64(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not INT64_MIN <= value <= INT64_MAX:
        raise CanonicalJSONError("integerNotInt64")
    return value


def _object_from_pairs(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CanonicalJSONError("duplicateKey")
        result[key] = value
    return result


def _parse_integer(token: str) -> int:
    if token == "-0":
        raise CanonicalJSONError("negativeZero")
    value = int(token, 10)
    if value < INT64_MIN:
        raise CanonicalJSONError("signedOverflow")
    if value > UINT64_MAX:
        raise CanonicalJSONError("unsignedOverflow")
    return value


def _reject_float(token: str) -> Any:
    raise CanonicalJSONError("unsupportedNumber", token)


def _reject_constant(token: str) -> Any:
    raise CanonicalJSONError("unsupportedNumber", token)


def _validate_unicode_scalars(value: Any) -> None:
    if isinstance(value, str):
        if any(0xD800 <= ord(character) <= 0xDFFF for character in value):
            raise CanonicalJSONError("invalidUnicodeEscape")
    elif isinstance(value, dict):
        for key, child in value.items():
            _validate_unicode_scalars(key)
            _validate_unicode_scalars(child)
    elif isinstance(value, list):
        for child in value:
            _validate_unicode_scalars(child)


def _encode_value(value: Any) -> str:
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        if value < INT64_MIN:
            raise CanonicalJSONError("signedOverflow")
        if value > UINT64_MAX:
            raise CanonicalJSONError("unsignedOverflow")
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    if isinstance(value, list):
        return "[" + ",".join(_encode_value(child) for child in value) + "]"
    if isinstance(value, dict):
        pairs = []
        for key in sorted(value):
            if not isinstance(key, str):
                raise CanonicalJSONError("invalidObjectKey")
            pairs.append(_encode_value(key) + ":" + _encode_value(value[key]))
        return "{" + ",".join(pairs) + "}"
    raise CanonicalJSONError("unsupportedValue")
