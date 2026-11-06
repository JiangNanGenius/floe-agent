/*
 * fmjson.h — narrow, finite, allocation-light JSON reader/writer for the
 * TurningNative C ABI boundary. Written for this prototype (no external
 * dependency). It intentionally supports only the JSON subset used by the
 * manufacturing request/contract: objects, arrays, strings, numbers
 * (double), booleans, null. Numbers must be finite; deeply nested or
 * oversized input is rejected. Not a general-purpose JSON library.
 */
#ifndef FMJSON_H
#define FMJSON_H

#include <cstdint>
#include <charconv>
#include <limits>
#include <stdexcept>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>

namespace fmjson
{

struct Value
{
    enum Type
    {
        Null,
        Bool,
        Number,
        String,
        Array,
        Object
    } type = Null;
    bool boolean = false;
    double number = 0;
    std::string str;
    std::vector<Value> items;
    std::vector<std::pair<std::string, Value>> members;

    const Value *find(const char *key) const
    {
        if (type != Object)
            return nullptr;
        for (const auto &m : members)
            if (m.first == key)
                return &m.second;
        return nullptr;
    }
};

class ParseError
{
public:
    explicit ParseError(const char *m) : msg(m) {}
    std::string msg;
};

class Parser
{
public:
    explicit Parser(const char *text) : cur(text ? text : ""), start(text ? text : "")
    {
        if (!text)
            throw ParseError("null input");
    }

    Value parseDocument()
    {
        skipWs();
        Value v = parseValue(0);
        skipWs();
        if (*cur != '\0')
            throw ParseError("trailing data after JSON document");
        return v;
    }

private:
    const char *cur;
    const char *start;
    static const int kMaxDepth = 48;
    static const long kMaxInput = 16L * 1024 * 1024;

    [[noreturn]] void fail(const char *msg)
    {
        throw ParseError(msg);
    }

    void skipWs()
    {
        while (*cur == ' ' || *cur == '\t' || *cur == '\n' || *cur == '\r')
            ++cur;
        if (cur - start > kMaxInput)
            fail("input exceeds size limit");
    }

    char peek()
    {
        return *cur;
    }

    char take()
    {
        if (*cur == '\0')
            fail("unexpected end of input");
        return *cur++;
    }

    void expect(char c)
    {
        if (take() != c)
            fail("unexpected character");
    }

    bool consumeLiteral(const char *lit)
    {
        size_t n = std::strlen(lit);
        if (std::strncmp(cur, lit, n) == 0)
        {
            cur += n;
            return true;
        }
        return false;
    }

    Value parseValue(int depth)
    {
        if (depth > kMaxDepth)
            fail("nesting too deep");
        skipWs();
        switch (peek())
        {
        case '{':
            return parseObject(depth);
        case '[':
            return parseArray(depth);
        case '"':
        {
            Value v;
            v.type = Value::String;
            v.str = parseString();
            return v;
        }
        case 't':
            if (!consumeLiteral("true"))
                fail("invalid literal");
        {
            Value v;
            v.type = Value::Bool;
            v.boolean = true;
            return v;
        }
        case 'f':
            if (!consumeLiteral("false"))
                fail("invalid literal");
        {
            Value v;
            v.type = Value::Bool;
            v.boolean = false;
            return v;
        }
        case 'n':
            if (!consumeLiteral("null"))
                fail("invalid literal");
            return Value();
        default:
            return parseNumber();
        }
    }

    Value parseNumber()
    {
        const char *begin = cur;
        if (peek() == '-')
            ++cur;
        if (*cur < '0' || *cur > '9')
            fail("invalid number");
        while (*cur >= '0' && *cur <= '9')
            ++cur;
        if (peek() == '.')
        {
            ++cur;
            if (!(*cur >= '0' && *cur <= '9'))
                fail("invalid fraction");
            while (*cur >= '0' && *cur <= '9')
                ++cur;
        }
        if (peek() == 'e' || peek() == 'E')
        {
            ++cur;
            if (peek() == '+' || peek() == '-')
                ++cur;
            if (!(*cur >= '0' && *cur <= '9'))
                fail("invalid exponent");
            while (*cur >= '0' && *cur <= '9')
                ++cur;
        }
        std::string text(begin, cur);
        double v = std::strtod(text.c_str(), nullptr);
        if (!std::isfinite(v))
            fail("number out of range");
        Value out;
        out.type = Value::Number;
        out.number = v;
        return out;
    }

    std::string parseString()
    {
        expect('"');
        std::string out;
        for (;;)
        {
            char c = take();
            if (c == '"')
                break;
            if ((unsigned char)c < 0x20)
                fail("unescaped control character");
            if (c == '\\')
            {
                char e = take();
                switch (e)
                {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u':
                    /* Non-ASCII \u escapes are not needed by the contract;
                     * accept ASCII \u00XX and reject the rest. */
                    for (int i = 0; i < 4; ++i)
                    {
                        char h = take();
                        if (!((h >= '0' && h <= '9') || (h >= 'a' && h <= 'f') || (h >= 'A' && h <= 'F')))
                            fail("invalid unicode escape");
                        if (i < 2 && h != '0')
                            fail("non-ASCII unicode escape unsupported");
                    }
                    out += '\0';
                    break;
                default:
                    fail("invalid escape");
                }
            }
            else
            {
                out += c;
            }
        }
        return out;
    }

    Value parseArray(int depth)
    {
        expect('[');
        Value v;
        v.type = Value::Array;
        skipWs();
        if (peek() == ']')
        {
            ++cur;
            return v;
        }
        for (;;)
        {
            v.items.push_back(parseValue(depth + 1));
            skipWs();
            char c = take();
            if (c == ']')
                break;
            if (c != ',')
                fail("expected ',' or ']'");
        }
        return v;
    }

    Value parseObject(int depth)
    {
        expect('{');
        Value v;
        v.type = Value::Object;
        skipWs();
        if (peek() == '}')
        {
            ++cur;
            return v;
        }
        for (;;)
        {
            skipWs();
            std::string key = parseString();
            skipWs();
            expect(':');
            v.members.emplace_back(std::move(key), parseValue(depth + 1));
            skipWs();
            char c = take();
            if (c == '}')
                break;
            if (c != ',')
                fail("expected ',' or '}'");
        }
        return v;
    }
};

/* ---------- writer ---------- */

class Writer
{
public:
    Writer() { out.reserve(4096); }

    const std::string &str() const { return out; }

    void raw(const char *s) { out += s; }

    void string(const std::string &s)
    {
        out += '"';
        for (char c : s)
        {
            switch (c)
            {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if ((unsigned char)c < 0x20)
                {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", (unsigned char)c);
                    out += buf;
                }
                else
                {
                    out += c;
                }
            }
        }
        out += '"';
    }

    /* Legacy six-decimal geometry formatting; retained for old responses. */
    void number(double v)
    {
        if (!std::isfinite(v))
        {
            out += "null";
            return;
        }
        char buf[32];
        std::snprintf(buf, sizeof(buf), "%.6f", v);
        /* trim trailing zeros */
        std::string s(buf);
        if (s.find('.') != std::string::npos)
        {
            while (!s.empty() && s.back() == '0')
                s.pop_back();
            if (!s.empty() && s.back() == '.')
                s.pop_back();
        }
        if (s == "-0")
            s = "0";
        out += s;
    }


    // R4 explicit settings/motion: locale-independent round-trip precision.
    // Legacy number() remains unchanged for absent turningSetup.
    void numberPrecise(double v)
    {
        if (!std::isfinite(v)) throw std::runtime_error("non-finite output number");
        char buffer[64];
        const auto result = std::to_chars(buffer,buffer+sizeof(buffer),v,std::chars_format::general,
                                          std::numeric_limits<double>::max_digits10);
        if (result.ec != std::errc{}) throw std::runtime_error("number formatting failed");
        out.append(buffer,result.ptr);
    }

private:
    std::string out;
};

} // namespace fmjson

#endif /* FMJSON_H */
