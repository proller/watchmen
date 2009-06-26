# New ports collection makefile for:	watchmen
# Date created:		2009-06-26
# Whom:			Oleg Alexeenkov <proler@gmail.com>
#
# $FreeBSD$
#

PORTNAME=	watchmen
PORTVERSION=	0.0.1
CATEGORIES=	sysutils
MASTER_SITES=	http://watchmen.googlecode.com/svn/trunk/
DISTFILES=	${PORTNAME}.pl ${PORTNAME}.conf.pl.dist
EXTRACT_ONLY=

MAINTAINER=	proler@gmail.com
COMMENT=	Watch and restart daemons

RUN_DEPENDS+=	${SITE_PERL}/LWP.pm:${PORTSDIR}/www/p5-libwww


USE_PERL5_RUN=	yes
POD2MAN?=	pod2man

MAN1=		${PORTNAME}.1
PLIST_FILES=	bin/${PORTNAME} etc/${PORTNAME}.conf.pl.dist

.include <bsd.port.pre.mk>

.if ${PERL_LEVEL} < 500805
RUN_DEPENDS+=	p5-Time-HiRes>=0:${PORTSDIR}/devel/p5-Time-HiRes
.endif

do-build:
	${MKDIR} ${WRKSRC}
	${CP} -f ${DISTDIR}/${PORTNAME}.pl ${WRKSRC}/${PORTNAME}
	${CP} -f ${DISTDIR}/${PORTNAME}.conf.pl.dist ${WRKSRC}/
	@cd ${WRKSRC} && ${POD2MAN} ${PORTNAME} > ${PORTNAME}.1

do-install:
	${INSTALL_SCRIPT} ${WRKSRC}/${PORTNAME} ${PREFIX}/bin
	${INSTALL_DATA} ${WRKSRC}/${PORTNAME}.conf.pl.dist ${PREFIX}/etc
	${INSTALL_MAN} ${WRKSRC}/${MAN1} ${MAN1PREFIX}/man/man1

.include <bsd.port.post.mk>
